{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Secret-safe, bidirectional parent/child federation registration.
--
-- Pre-Vault bootstrap is a two-worker handshake.  A child-local, attested
-- recipient Job publishes only an ephemeral public key.  An exact selected
-- parent Agent launches a one-shot worker that creates the scoped Transit
-- credential and returns only ciphertext for that child key.  The child Job
-- decrypts in memory, CAS/read-backs its local transit-seal Secret, and sends
-- metadata/kubeconfig back encrypted to the parent's non-exportable recipient.
-- The same parent worker commits metadata/bootstrap/index custody and both
-- workers are proved absent.  Authority state contains public keys,
-- ciphertext, commitments, identities and absence proofs only.
--
-- After child initialization, the same retained aggregate accepts the
-- Broker's encrypted recovery receipt, records the parent-custody intent
-- before the exact parent Agent call, and completes only after read-back.
module Prodbox.Cluster.FederationRegistration
  ( ChildKubernetesUid
  , mkChildKubernetesUid
  , childKubernetesUidText
  , FederationWorkerBinding (..)
  , mkFederationWorkerBinding
  , FederationWorkerCleanup (..)
  , mkFederationWorkerCleanup
  , ChildBootstrapDeliveryIntent (..)
  , mkChildBootstrapDeliveryIntent
  , validateChildBootstrapDeliveryIntent
  , childBootstrapDeliveryTargetAgent
  , ChildBootstrapRecipientAttestation (..)
  , mkChildBootstrapRecipientAttestation
  , validateChildBootstrapRecipientAttestation
  , ParentBootstrapEnvelope (..)
  , mkParentBootstrapEnvelope
  , validateParentBootstrapEnvelope
  , ChildBootstrapDeliveryReceipt (..)
  , mkChildBootstrapDeliveryReceipt
  , validateChildBootstrapDeliveryReceipt
  , ParentBootstrapCustodyReceipt (..)
  , mkParentBootstrapCustodyReceipt
  , validateParentBootstrapCustodyReceipt
  , bootstrapCustodyIntent
  , ChildCustodyExport (..)
  , mkChildCustodyExport
  , childCustodyExportCommitment
  , validateChildCustodyExport
  , FederationRegistrationIntent (..)
  , mkFederationRegistrationIntent
  , validateFederationRegistrationIntent
  , federationRegistrationTargetAgent
  , FederationRegistrationCompletion (..)
  , mkFederationRegistrationCompletion
  , validateFederationRegistrationCompletion
  , FederationRegistrationState (..)
  , FederationRegistrationCommand (..)
  , FederationRegistrationError (..)
  , newFederationRegistrationState
  , applyFederationRegistrationCommand
  , registrationStateBootstrapIntent
  , registrationStateChildRecipient
  , registrationStateParentEnvelope
  , registrationStateChildDelivery
  , registrationStateBootstrapCustody
  , registrationStateCustodyIntent
  , registrationStateCompletion
  )
where

import Codec.Serialise (Serialise, serialise)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word8)
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Request (RequestDigest)
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , ChildEncryptedReceipt (..)
  , ParentCustodyAcknowledgement (..)
  , mkArtifactDigest
  , renderArtifactDigest
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentIdentity
  , mkTargetAgentIdentity
  , targetAgentClusterIdentity
  , targetAgentIdentityText
  , targetAgentRolloutDigest
  )

newtype ChildKubernetesUid = ChildKubernetesUid Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

mkChildKubernetesUid :: Text -> Either Text ChildKubernetesUid
mkChildKubernetesUid raw =
  ChildKubernetesUid
    <$> validateTokenText "child Kubernetes UID" 128 raw

childKubernetesUidText :: ChildKubernetesUid -> Text
childKubernetesUidText (ChildKubernetesUid value) = value

-- | Exact API-assigned identity of one one-shot federation worker.  The
-- rollout digest binds the immutable worker image/config incarnation; Job,
-- Pod and ServiceAccount UIDs prevent a same-name replacement from borrowing
-- a permit.
data FederationWorkerBinding = FederationWorkerBinding
  { federationWorkerCluster :: !Text
  , federationWorkerRolloutDigest :: !ArtifactDigest
  , federationWorkerJobUid :: !Text
  , federationWorkerPodUid :: !Text
  , federationWorkerServiceAccount :: !Text
  , federationWorkerServiceAccountUid :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkFederationWorkerBinding
  :: Text
  -> ArtifactDigest
  -> Text
  -> Text
  -> Text
  -> Text
  -> Either FederationRegistrationError FederationWorkerBinding
mkFederationWorkerBinding rawCluster rollout rawJobUid rawPodUid rawServiceAccount rawServiceAccountUid = do
  cluster <- validateClusterIdentity rawCluster
  jobUid <- workerIdentity rawJobUid
  podUid <- workerIdentity rawPodUid
  serviceAccount <- workerIdentity rawServiceAccount
  serviceAccountUid <- workerIdentity rawServiceAccountUid
  Right
    FederationWorkerBinding
      { federationWorkerCluster = cluster
      , federationWorkerRolloutDigest = rollout
      , federationWorkerJobUid = jobUid
      , federationWorkerPodUid = podUid
      , federationWorkerServiceAccount = serviceAccount
      , federationWorkerServiceAccountUid = serviceAccountUid
      }
 where
  workerIdentity =
    mapLeftRegistration FederationRegistrationWorkerIdentityInvalid
      . validateTokenText "federation worker identity" 256

-- | Terminal absence proof for a worker.  The opaque session attestation is
-- required even for a pre-Vault child worker: in that case it commits the
-- explicit no-session-issued observation.  Job and Pod absence are separate
-- read-backs and cannot be inferred from deletion acceptance.
data FederationWorkerCleanup = FederationWorkerCleanup
  { federationWorkerCleanupBinding :: !FederationWorkerBinding
  , federationWorkerSessionAbsence :: !ArtifactDigest
  , federationWorkerJobAbsence :: !ArtifactDigest
  , federationWorkerPodAbsence :: !ArtifactDigest
  , federationWorkerCleanupDigest :: !ArtifactDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkFederationWorkerCleanup
  :: FederationWorkerBinding
  -> ArtifactDigest
  -> ArtifactDigest
  -> ArtifactDigest
  -> FederationWorkerCleanup
mkFederationWorkerCleanup binding sessionAbsence jobAbsence podAbsence =
  let cleanupDigest =
        digestSerialised
          ( "prodbox-federation-worker-cleanup-v1" :: Text
          , binding
          , sessionAbsence
          , jobAbsence
          , podAbsence
          )
   in FederationWorkerCleanup
        { federationWorkerCleanupBinding = binding
        , federationWorkerSessionAbsence = sessionAbsence
        , federationWorkerJobAbsence = jobAbsence
        , federationWorkerPodAbsence = podAbsence
        , federationWorkerCleanupDigest = cleanupDigest
        }

validateFederationWorkerCleanup
  :: FederationWorkerCleanup
  -> Either FederationRegistrationError FederationWorkerCleanup
validateFederationWorkerCleanup cleanup =
  if rebuilt == cleanup
    then Right cleanup
    else Left FederationRegistrationWorkerCleanupInvalid
 where
  rebuilt =
    mkFederationWorkerCleanup
      (federationWorkerCleanupBinding cleanup)
      (federationWorkerSessionAbsence cleanup)
      (federationWorkerJobAbsence cleanup)
      (federationWorkerPodAbsence cleanup)

-- | Secret-free durable registration anchor.  Both worker rollouts and
-- ServiceAccounts are fixed before either Job is created.  Endpoint text is
-- external and HTTPS: a child never guesses a cluster-local Authority DNS
-- name.  The absolute deadline is shared by the complete two-worker exchange.
data ChildBootstrapDeliveryIntent = ChildBootstrapDeliveryIntent
  { childBootstrapDeliveryParentCluster :: !Text
  , childBootstrapDeliveryChildCluster :: !Text
  , childBootstrapDeliveryChildKubernetesUid :: !ChildKubernetesUid
  , childBootstrapDeliveryTargetAgentText :: !Text
  , childBootstrapDeliveryParentAuthorityEndpoint :: !Text
  , childBootstrapDeliveryParentVaultAddress :: !Text
  , childBootstrapDeliveryTransitKey :: !Text
  , childBootstrapDeliveryParentWorkerRollout :: !ArtifactDigest
  , childBootstrapDeliveryChildWorkerRollout :: !ArtifactDigest
  , childBootstrapDeliveryParentWorkerServiceAccount :: !Text
  , childBootstrapDeliveryChildWorkerServiceAccount :: !Text
  , childBootstrapDeliveryParentGeneration :: !Natural
  , childBootstrapDeliveryChildGeneration :: !Natural
  , childBootstrapDeliveryDeadlineMicros :: !Natural
  , childBootstrapDeliveryRequestDigest :: !RequestDigest
  , childBootstrapDeliveryActionDigest :: !ArtifactDigest
  , childBootstrapDeliveryMaterialCommitment :: !ArtifactDigest
  , childBootstrapDeliveryOperationDigest :: !ArtifactDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ChildBootstrapDeliveryDigestInput = ChildBootstrapDeliveryDigestInput
  { digestInputParentCluster :: !Text
  , digestInputChildCluster :: !Text
  , digestInputChildUid :: !ChildKubernetesUid
  , digestInputTargetAgent :: !Text
  , digestInputAuthorityEndpoint :: !Text
  , digestInputVaultAddress :: !Text
  , digestInputTransitKey :: !Text
  , digestInputParentRollout :: !ArtifactDigest
  , digestInputChildRollout :: !ArtifactDigest
  , digestInputParentServiceAccount :: !Text
  , digestInputChildServiceAccount :: !Text
  , digestInputParentGeneration :: !Natural
  , digestInputChildGeneration :: !Natural
  , digestInputDeadlineMicros :: !Natural
  , digestInputRequestDigest :: !RequestDigest
  , digestInputActionDigest :: !ArtifactDigest
  , digestInputMaterialCommitment :: !ArtifactDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkChildBootstrapDeliveryIntent
  :: Text
  -> Text
  -> ChildKubernetesUid
  -> TargetAgentIdentity
  -> Text
  -> Text
  -> Text
  -> ArtifactDigest
  -> ArtifactDigest
  -> Text
  -> Text
  -> Natural
  -> Natural
  -> Natural
  -> RequestDigest
  -> ArtifactDigest
  -> ArtifactDigest
  -> Either FederationRegistrationError ChildBootstrapDeliveryIntent
mkChildBootstrapDeliveryIntent rawParent rawChild childUid targetAgent rawAuthorityEndpoint rawVaultAddress rawTransitKey parentRollout childRollout rawParentServiceAccount rawChildServiceAccount parentGeneration childGeneration deadlineMicros requestDigest actionDigest materialCommitment = do
  parent <- validateClusterIdentity rawParent
  child <- validateChildClusterIdentity rawChild
  authorityEndpoint <- validateParentAuthorityEndpoint rawAuthorityEndpoint
  vaultAddress <- bounded FederationRegistrationParentVaultAddressInvalid 2048 rawVaultAddress
  transitKey <- bounded FederationRegistrationTransitKeyInvalid 256 rawTransitKey
  parentServiceAccount <-
    bounded FederationRegistrationWorkerIdentityInvalid 256 rawParentServiceAccount
  childServiceAccount <-
    bounded FederationRegistrationWorkerIdentityInvalid 256 rawChildServiceAccount
  if child == parent then Left FederationRegistrationChildEqualsParent else Right ()
  if targetAgentClusterIdentity targetAgent /= parent
    then Left FederationRegistrationTargetAgentClusterMismatch
    else Right ()
  if targetAgentRolloutDigest targetAgent
    /= "sha256:" <> renderArtifactDigest parentRollout
    then Left FederationRegistrationTargetAgentRolloutMismatch
    else Right ()
  if parentGeneration == 0 || childGeneration == 0 || deadlineMicros == 0
    then Left FederationRegistrationGenerationOrDeadlineInvalid
    else Right ()
  let targetText = targetAgentIdentityText targetAgent
      operationDigest =
        digestSerialised
          ( "prodbox-federation-registration-operation-v3" :: Text
          , ChildBootstrapDeliveryDigestInput
              { digestInputParentCluster = parent
              , digestInputChildCluster = child
              , digestInputChildUid = childUid
              , digestInputTargetAgent = targetText
              , digestInputAuthorityEndpoint = authorityEndpoint
              , digestInputVaultAddress = vaultAddress
              , digestInputTransitKey = transitKey
              , digestInputParentRollout = parentRollout
              , digestInputChildRollout = childRollout
              , digestInputParentServiceAccount = parentServiceAccount
              , digestInputChildServiceAccount = childServiceAccount
              , digestInputParentGeneration = parentGeneration
              , digestInputChildGeneration = childGeneration
              , digestInputDeadlineMicros = deadlineMicros
              , digestInputRequestDigest = requestDigest
              , digestInputActionDigest = actionDigest
              , digestInputMaterialCommitment = materialCommitment
              }
          )
  Right
    ChildBootstrapDeliveryIntent
      { childBootstrapDeliveryParentCluster = parent
      , childBootstrapDeliveryChildCluster = child
      , childBootstrapDeliveryChildKubernetesUid = childUid
      , childBootstrapDeliveryTargetAgentText = targetText
      , childBootstrapDeliveryParentAuthorityEndpoint = authorityEndpoint
      , childBootstrapDeliveryParentVaultAddress = vaultAddress
      , childBootstrapDeliveryTransitKey = transitKey
      , childBootstrapDeliveryParentWorkerRollout = parentRollout
      , childBootstrapDeliveryChildWorkerRollout = childRollout
      , childBootstrapDeliveryParentWorkerServiceAccount = parentServiceAccount
      , childBootstrapDeliveryChildWorkerServiceAccount = childServiceAccount
      , childBootstrapDeliveryParentGeneration = parentGeneration
      , childBootstrapDeliveryChildGeneration = childGeneration
      , childBootstrapDeliveryDeadlineMicros = deadlineMicros
      , childBootstrapDeliveryRequestDigest = requestDigest
      , childBootstrapDeliveryActionDigest = actionDigest
      , childBootstrapDeliveryMaterialCommitment = materialCommitment
      , childBootstrapDeliveryOperationDigest = operationDigest
      }

validateChildBootstrapDeliveryIntent
  :: ChildBootstrapDeliveryIntent
  -> Either FederationRegistrationError ChildBootstrapDeliveryIntent
validateChildBootstrapDeliveryIntent intent = do
  target <- childBootstrapDeliveryTargetAgent intent
  rebuilt <-
    mkChildBootstrapDeliveryIntent
      (childBootstrapDeliveryParentCluster intent)
      (childBootstrapDeliveryChildCluster intent)
      (childBootstrapDeliveryChildKubernetesUid intent)
      target
      (childBootstrapDeliveryParentAuthorityEndpoint intent)
      (childBootstrapDeliveryParentVaultAddress intent)
      (childBootstrapDeliveryTransitKey intent)
      (childBootstrapDeliveryParentWorkerRollout intent)
      (childBootstrapDeliveryChildWorkerRollout intent)
      (childBootstrapDeliveryParentWorkerServiceAccount intent)
      (childBootstrapDeliveryChildWorkerServiceAccount intent)
      (childBootstrapDeliveryParentGeneration intent)
      (childBootstrapDeliveryChildGeneration intent)
      (childBootstrapDeliveryDeadlineMicros intent)
      (childBootstrapDeliveryRequestDigest intent)
      (childBootstrapDeliveryActionDigest intent)
      (childBootstrapDeliveryMaterialCommitment intent)
  if rebuilt == intent then Right intent else Left FederationRegistrationOperationDigestMismatch

childBootstrapDeliveryTargetAgent
  :: ChildBootstrapDeliveryIntent
  -> Either FederationRegistrationError TargetAgentIdentity
childBootstrapDeliveryTargetAgent intent =
  mapLeftRegistration
    FederationRegistrationTargetAgentInvalid
    (mkTargetAgentIdentity (childBootstrapDeliveryTargetAgentText intent))

-- | First durable worker result: the child Job is running and publishes only
-- an ephemeral recipient public key.
data ChildBootstrapRecipientAttestation = ChildBootstrapRecipientAttestation
  { childBootstrapRecipientIntent :: !ChildBootstrapDeliveryIntent
  , childBootstrapRecipientWorker :: !FederationWorkerBinding
  , childBootstrapRecipientPublicKey :: !ByteString
  , childBootstrapRecipientPublicKeyDigest :: !ArtifactDigest
  , childBootstrapRecipientAttestationDigest :: !ArtifactDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkChildBootstrapRecipientAttestation
  :: ChildBootstrapDeliveryIntent
  -> FederationWorkerBinding
  -> ByteString
  -> Either FederationRegistrationError ChildBootstrapRecipientAttestation
mkChildBootstrapRecipientAttestation intent worker publicKey = do
  _ <- validateChildBootstrapDeliveryIntent intent
  validateWorkerForIntent False intent worker
  validatePublicKey publicKey
  let keyDigest = digestBytes "prodbox-federation-child-recipient-key-v1" publicKey
      attestationDigest =
        digestSerialised
          ( "prodbox-federation-child-recipient-attestation-v1" :: Text
          , intent
          , worker
          , keyDigest
          )
  Right
    ChildBootstrapRecipientAttestation
      { childBootstrapRecipientIntent = intent
      , childBootstrapRecipientWorker = worker
      , childBootstrapRecipientPublicKey = publicKey
      , childBootstrapRecipientPublicKeyDigest = keyDigest
      , childBootstrapRecipientAttestationDigest = attestationDigest
      }

validateChildBootstrapRecipientAttestation
  :: ChildBootstrapRecipientAttestation
  -> Either FederationRegistrationError ChildBootstrapRecipientAttestation
validateChildBootstrapRecipientAttestation attestation = do
  rebuilt <-
    mkChildBootstrapRecipientAttestation
      (childBootstrapRecipientIntent attestation)
      (childBootstrapRecipientWorker attestation)
      (childBootstrapRecipientPublicKey attestation)
  if rebuilt == attestation
    then Right attestation
    else Left FederationRegistrationChildRecipientInvalid

-- | Parent worker output.  The scoped Transit credential exists only inside
-- the child-key-encrypted envelope.  The second public key belongs to the
-- same running parent worker and is used for the encrypted return payload.
data ParentBootstrapEnvelope = ParentBootstrapEnvelope
  { parentBootstrapEnvelopeChildRecipient :: !ChildBootstrapRecipientAttestation
  , parentBootstrapEnvelopeWorker :: !FederationWorkerBinding
  , parentBootstrapEnvelopeCustodyPublicKey :: !ByteString
  , parentBootstrapEnvelopeCustodyPublicKeyDigest :: !ArtifactDigest
  , parentBootstrapEnvelopeCiphertext :: !ByteString
  , parentBootstrapEnvelopeCredentialCommitment :: !ArtifactDigest
  , parentBootstrapEnvelopeDigest :: !ArtifactDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkParentBootstrapEnvelope
  :: ChildBootstrapRecipientAttestation
  -> FederationWorkerBinding
  -> ByteString
  -> ByteString
  -> ArtifactDigest
  -> Either FederationRegistrationError ParentBootstrapEnvelope
mkParentBootstrapEnvelope recipient worker custodyPublicKey ciphertext credentialCommitment = do
  _ <- validateChildBootstrapRecipientAttestation recipient
  let intent = childBootstrapRecipientIntent recipient
  validateWorkerForIntent True intent worker
  validatePublicKey custodyPublicKey
  validateCiphertext ciphertext
  let keyDigest = digestBytes "prodbox-federation-parent-custody-key-v1" custodyPublicKey
      envelopeDigest =
        digestSerialised
          ( "prodbox-federation-parent-bootstrap-envelope-v1" :: Text
          , recipient
          , worker
          , keyDigest
          , digestBytes "prodbox-federation-transit-envelope-v1" ciphertext
          , credentialCommitment
          )
  Right
    ParentBootstrapEnvelope
      { parentBootstrapEnvelopeChildRecipient = recipient
      , parentBootstrapEnvelopeWorker = worker
      , parentBootstrapEnvelopeCustodyPublicKey = custodyPublicKey
      , parentBootstrapEnvelopeCustodyPublicKeyDigest = keyDigest
      , parentBootstrapEnvelopeCiphertext = ciphertext
      , parentBootstrapEnvelopeCredentialCommitment = credentialCommitment
      , parentBootstrapEnvelopeDigest = envelopeDigest
      }

validateParentBootstrapEnvelope
  :: ParentBootstrapEnvelope
  -> Either FederationRegistrationError ParentBootstrapEnvelope
validateParentBootstrapEnvelope envelope = do
  rebuilt <-
    mkParentBootstrapEnvelope
      (parentBootstrapEnvelopeChildRecipient envelope)
      (parentBootstrapEnvelopeWorker envelope)
      (parentBootstrapEnvelopeCustodyPublicKey envelope)
      (parentBootstrapEnvelopeCiphertext envelope)
      (parentBootstrapEnvelopeCredentialCommitment envelope)
  if rebuilt == envelope
    then Right envelope
    else Left FederationRegistrationParentEnvelopeInvalid

-- | Child worker output after local Secret CAS/read-back.  Metadata and
-- kubeconfig are present only in ciphertext for the parent worker's key.
data ChildBootstrapDeliveryReceipt = ChildBootstrapDeliveryReceipt
  { childBootstrapDeliveryParentEnvelope :: !ParentBootstrapEnvelope
  , childBootstrapDeliveryWorker :: !FederationWorkerBinding
  , childBootstrapDeliveryChildSecretUid :: !ChildKubernetesUid
  , childBootstrapDeliveryChildSecretResourceVersion :: !Text
  , childBootstrapDeliveryChildSecretCommitment :: !ArtifactDigest
  , childBootstrapDeliveryParentCiphertext :: !ByteString
  , childBootstrapDeliveryParentCiphertextDigest :: !ArtifactDigest
  , childBootstrapDeliveryCleanup :: !FederationWorkerCleanup
  , childBootstrapDeliveryAcknowledgement :: !ArtifactDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkChildBootstrapDeliveryReceipt
  :: ParentBootstrapEnvelope
  -> FederationWorkerBinding
  -> ChildKubernetesUid
  -> Text
  -> ArtifactDigest
  -> ByteString
  -> FederationWorkerCleanup
  -> Either FederationRegistrationError ChildBootstrapDeliveryReceipt
mkChildBootstrapDeliveryReceipt parentEnvelope worker childSecretUid rawResourceVersion childSecretCommitment parentCiphertext cleanup = do
  _ <- validateParentBootstrapEnvelope parentEnvelope
  let recipient = parentBootstrapEnvelopeChildRecipient parentEnvelope
      intent = childBootstrapRecipientIntent recipient
  if worker /= childBootstrapRecipientWorker recipient
    then Left FederationRegistrationWorkerSubstitution
    else Right ()
  _ <- validateFederationWorkerCleanup cleanup
  if federationWorkerCleanupBinding cleanup /= worker
    then Left FederationRegistrationWorkerSubstitution
    else Right ()
  resourceVersion <-
    bounded FederationRegistrationChildSecretResourceVersionInvalid 256 rawResourceVersion
  validateCiphertext parentCiphertext
  let ciphertextDigest =
        digestBytes "prodbox-federation-parent-return-envelope-v1" parentCiphertext
      acknowledgement =
        digestSerialised
          ( "prodbox-child-bootstrap-delivery-ack-v2" :: Text
          , parentBootstrapEnvelopeDigest parentEnvelope
          , worker
          , childBootstrapDeliveryChildKubernetesUid intent
          , childSecretUid
          , resourceVersion
          , childSecretCommitment
          , ciphertextDigest
          , cleanup
          )
  Right
    ChildBootstrapDeliveryReceipt
      { childBootstrapDeliveryParentEnvelope = parentEnvelope
      , childBootstrapDeliveryWorker = worker
      , childBootstrapDeliveryChildSecretUid = childSecretUid
      , childBootstrapDeliveryChildSecretResourceVersion = resourceVersion
      , childBootstrapDeliveryChildSecretCommitment = childSecretCommitment
      , childBootstrapDeliveryParentCiphertext = parentCiphertext
      , childBootstrapDeliveryParentCiphertextDigest = ciphertextDigest
      , childBootstrapDeliveryCleanup = cleanup
      , childBootstrapDeliveryAcknowledgement = acknowledgement
      }

validateChildBootstrapDeliveryReceipt
  :: ChildBootstrapDeliveryReceipt
  -> Either FederationRegistrationError ChildBootstrapDeliveryReceipt
validateChildBootstrapDeliveryReceipt receipt = do
  rebuilt <-
    mkChildBootstrapDeliveryReceipt
      (childBootstrapDeliveryParentEnvelope receipt)
      (childBootstrapDeliveryWorker receipt)
      (childBootstrapDeliveryChildSecretUid receipt)
      (childBootstrapDeliveryChildSecretResourceVersion receipt)
      (childBootstrapDeliveryChildSecretCommitment receipt)
      (childBootstrapDeliveryParentCiphertext receipt)
      (childBootstrapDeliveryCleanup receipt)
  if rebuilt == receipt
    then Right receipt
    else Left FederationRegistrationBootstrapAcknowledgementMismatch

-- | Final pre-init result.  Parent metadata/bootstrap/index custody is exact,
-- and neither worker is considered complete before its Vault session (or
-- explicit no-session observation), Job and Pod are all proved absent.
data ParentBootstrapCustodyReceipt = ParentBootstrapCustodyReceipt
  { parentBootstrapCustodyChildDelivery :: !ChildBootstrapDeliveryReceipt
  , parentBootstrapCustodyMetadataCommitment :: !ArtifactDigest
  , parentBootstrapCustodyBootstrapCommitment :: !ArtifactDigest
  , parentBootstrapCustodyIndexCommitment :: !ArtifactDigest
  , parentBootstrapCustodyChildCleanup :: !FederationWorkerCleanup
  , parentBootstrapCustodyParentCleanup :: !FederationWorkerCleanup
  , parentBootstrapCustodyAcknowledgement :: !ArtifactDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkParentBootstrapCustodyReceipt
  :: ChildBootstrapDeliveryReceipt
  -> ArtifactDigest
  -> ArtifactDigest
  -> ArtifactDigest
  -> FederationWorkerCleanup
  -> Either FederationRegistrationError ParentBootstrapCustodyReceipt
mkParentBootstrapCustodyReceipt delivery metadataCommitment bootstrapCommitment indexCommitment parentCleanup = do
  _ <- validateChildBootstrapDeliveryReceipt delivery
  _ <- validateFederationWorkerCleanup parentCleanup
  let envelope = childBootstrapDeliveryParentEnvelope delivery
  if federationWorkerCleanupBinding parentCleanup /= parentBootstrapEnvelopeWorker envelope
    then Left FederationRegistrationWorkerSubstitution
    else Right ()
  let acknowledgement =
        digestSerialised
          ( "prodbox-parent-bootstrap-custody-ack-v1" :: Text
          , delivery
          , metadataCommitment
          , bootstrapCommitment
          , indexCommitment
          , childBootstrapDeliveryCleanup delivery
          , parentCleanup
          )
  Right
    ParentBootstrapCustodyReceipt
      { parentBootstrapCustodyChildDelivery = delivery
      , parentBootstrapCustodyMetadataCommitment = metadataCommitment
      , parentBootstrapCustodyBootstrapCommitment = bootstrapCommitment
      , parentBootstrapCustodyIndexCommitment = indexCommitment
      , parentBootstrapCustodyChildCleanup = childBootstrapDeliveryCleanup delivery
      , parentBootstrapCustodyParentCleanup = parentCleanup
      , parentBootstrapCustodyAcknowledgement = acknowledgement
      }

validateParentBootstrapCustodyReceipt
  :: ParentBootstrapCustodyReceipt
  -> Either FederationRegistrationError ParentBootstrapCustodyReceipt
validateParentBootstrapCustodyReceipt receipt = do
  rebuilt <-
    mkParentBootstrapCustodyReceipt
      (parentBootstrapCustodyChildDelivery receipt)
      (parentBootstrapCustodyMetadataCommitment receipt)
      (parentBootstrapCustodyBootstrapCommitment receipt)
      (parentBootstrapCustodyIndexCommitment receipt)
      (parentBootstrapCustodyParentCleanup receipt)
  if rebuilt == receipt
    then Right receipt
    else Left FederationRegistrationParentBootstrapCustodyInvalid

bootstrapCustodyIntent
  :: ParentBootstrapCustodyReceipt -> ChildBootstrapDeliveryIntent
bootstrapCustodyIntent =
  childBootstrapRecipientIntent
    . parentBootstrapEnvelopeChildRecipient
    . childBootstrapDeliveryParentEnvelope
    . parentBootstrapCustodyChildDelivery

data ChildCustodyExport = ChildCustodyExport
  { childCustodyExportReceipt :: !ChildEncryptedReceipt
  , childCustodyExportRequestDigest :: !RequestDigest
  , childCustodyExportActionDigest :: !ArtifactDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkChildCustodyExport
  :: ChildEncryptedReceipt
  -> RequestDigest
  -> ArtifactDigest
  -> ChildCustodyExport
mkChildCustodyExport = ChildCustodyExport

validateChildCustodyExport
  :: ChildCustodyExport -> Either FederationRegistrationError ChildCustodyExport
validateChildCustodyExport exported
  | null (childEncryptedReceiptShares (childCustodyExportReceipt exported)) =
      Left FederationRegistrationEncryptedSharesEmpty
  | otherwise = Right exported

childCustodyExportCommitment :: ChildCustodyExport -> ArtifactDigest
childCustodyExportCommitment exported =
  digestSerialised ("prodbox-child-custody-export-v1" :: Text, exported)

data FederationRegistrationIntent = FederationRegistrationIntent
  { federationRegistrationParentCluster :: !Text
  , federationRegistrationChildKubernetesUid :: !ChildKubernetesUid
  , federationRegistrationTargetAgentText :: !Text
  , federationRegistrationBootstrapCustody :: !ParentBootstrapCustodyReceipt
  , federationRegistrationExport :: !ChildCustodyExport
  , federationRegistrationOperationDigest :: !ArtifactDigest
  , federationRegistrationCustodyDigest :: !ArtifactDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkFederationRegistrationIntent
  :: ParentBootstrapCustodyReceipt
  -> ChildCustodyExport
  -> Either FederationRegistrationError FederationRegistrationIntent
mkFederationRegistrationIntent bootstrapCustody exported = do
  _ <- validateParentBootstrapCustodyReceipt bootstrapCustody
  _ <- validateChildCustodyExport exported
  let deliveryIntent = bootstrapCustodyIntent bootstrapCustody
      parent = childBootstrapDeliveryParentCluster deliveryIntent
      childUid = childBootstrapDeliveryChildKubernetesUid deliveryIntent
      targetText = childBootstrapDeliveryTargetAgentText deliveryIntent
      operationDigest = childBootstrapDeliveryOperationDigest deliveryIntent
      custodyDigest =
        digestSerialised
          ( "prodbox-federation-registration-custody-v3" :: Text
          , bootstrapCustody
          , exported
          )
  Right
    FederationRegistrationIntent
      { federationRegistrationParentCluster = parent
      , federationRegistrationChildKubernetesUid = childUid
      , federationRegistrationTargetAgentText = targetText
      , federationRegistrationBootstrapCustody = bootstrapCustody
      , federationRegistrationExport = exported
      , federationRegistrationOperationDigest = operationDigest
      , federationRegistrationCustodyDigest = custodyDigest
      }

validateFederationRegistrationIntent
  :: FederationRegistrationIntent
  -> Either FederationRegistrationError FederationRegistrationIntent
validateFederationRegistrationIntent intent = do
  target <- federationRegistrationTargetAgent intent
  let deliveryIntent = bootstrapCustodyIntent (federationRegistrationBootstrapCustody intent)
  bootstrapTarget <- childBootstrapDeliveryTargetAgent deliveryIntent
  if target /= bootstrapTarget
    then Left FederationRegistrationTargetAgentClusterMismatch
    else Right ()
  rebuilt <-
    mkFederationRegistrationIntent
      (federationRegistrationBootstrapCustody intent)
      (federationRegistrationExport intent)
  if rebuilt == intent then Right intent else Left FederationRegistrationOperationDigestMismatch

federationRegistrationTargetAgent
  :: FederationRegistrationIntent
  -> Either FederationRegistrationError TargetAgentIdentity
federationRegistrationTargetAgent intent =
  mapLeftRegistration
    FederationRegistrationTargetAgentInvalid
    (mkTargetAgentIdentity (federationRegistrationTargetAgentText intent))

data FederationRegistrationCompletion = FederationRegistrationCompletion
  { federationRegistrationCompletedIntent :: !FederationRegistrationIntent
  , federationRegistrationAcknowledgement :: !ParentCustodyAcknowledgement
  , federationRegistrationCompletionDigest :: !ArtifactDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkFederationRegistrationCompletion
  :: FederationRegistrationIntent
  -> ParentCustodyAcknowledgement
  -> Either FederationRegistrationError FederationRegistrationCompletion
mkFederationRegistrationCompletion intent acknowledgement = do
  _ <- validateFederationRegistrationIntent intent
  let receipt = childCustodyExportReceipt (federationRegistrationExport intent)
  if parentCustodyAcknowledgedBinding acknowledgement /= childEncryptedReceiptBinding receipt
    then Left FederationRegistrationAcknowledgedBindingMismatch
    else Right ()
  if parentCustodyAcknowledgedReceiptDigest acknowledgement /= childEncryptedReceiptDigest receipt
    then Left FederationRegistrationAcknowledgedReceiptMismatch
    else Right ()
  let completionDigest =
        digestSerialised
          ( "prodbox-federation-registration-completion-v1" :: Text
          , intent
          , acknowledgement
          )
  Right
    FederationRegistrationCompletion
      { federationRegistrationCompletedIntent = intent
      , federationRegistrationAcknowledgement = acknowledgement
      , federationRegistrationCompletionDigest = completionDigest
      }

validateFederationRegistrationCompletion
  :: FederationRegistrationCompletion
  -> Either FederationRegistrationError FederationRegistrationCompletion
validateFederationRegistrationCompletion completion = do
  rebuilt <-
    mkFederationRegistrationCompletion
      (federationRegistrationCompletedIntent completion)
      (federationRegistrationAcknowledgement completion)
  if rebuilt == completion
    then Right completion
    else Left FederationRegistrationCompletionDigestMismatch

data FederationRegistrationState
  = FederationBootstrapPrepared !ChildBootstrapDeliveryIntent
  | FederationChildRecipientRecorded !ChildBootstrapRecipientAttestation
  | FederationParentEnvelopeRecorded !ParentBootstrapEnvelope
  | FederationChildDeliveryRecorded !ChildBootstrapDeliveryReceipt
  | FederationBootstrapCustodyCompleted !ParentBootstrapCustodyReceipt
  | FederationRegistrationPrepared !FederationRegistrationIntent
  | FederationRegistrationCompleted !FederationRegistrationCompletion
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data FederationRegistrationCommand
  = PrepareFederationBootstrap !ChildBootstrapDeliveryIntent
  | RecordFederationChildRecipient !ChildBootstrapRecipientAttestation
  | RecordFederationParentEnvelope !ParentBootstrapEnvelope
  | RecordFederationChildDelivery !ChildBootstrapDeliveryReceipt
  | CompleteFederationBootstrapCustody !ParentBootstrapCustodyReceipt
  | PrepareFederationRegistration !FederationRegistrationIntent
  | CompleteFederationRegistration !FederationRegistrationCompletion
  deriving stock (Eq, Show)

data FederationRegistrationError
  = FederationRegistrationParentClusterInvalid
  | FederationRegistrationChildClusterInvalid
  | FederationRegistrationChildEqualsParent
  | FederationRegistrationTargetAgentInvalid
  | FederationRegistrationTargetAgentClusterMismatch
  | FederationRegistrationTargetAgentRolloutMismatch
  | FederationRegistrationParentAuthorityEndpointInvalid
  | FederationRegistrationParentVaultAddressInvalid
  | FederationRegistrationTransitKeyInvalid
  | FederationRegistrationGenerationOrDeadlineInvalid
  | FederationRegistrationWorkerIdentityInvalid
  | FederationRegistrationWorkerSubstitution
  | FederationRegistrationWorkerCleanupInvalid
  | FederationRegistrationPublicKeyInvalid
  | FederationRegistrationCiphertextInvalid
  | FederationRegistrationChildRecipientInvalid
  | FederationRegistrationParentEnvelopeInvalid
  | FederationRegistrationChildSecretResourceVersionInvalid
  | FederationRegistrationBootstrapAcknowledgementMismatch
  | FederationRegistrationParentBootstrapCustodyInvalid
  | FederationRegistrationEncryptedSharesEmpty
  | FederationRegistrationOperationDigestMismatch
  | FederationRegistrationAcknowledgedBindingMismatch
  | FederationRegistrationAcknowledgedReceiptMismatch
  | FederationRegistrationCompletionDigestMismatch
  | FederationRegistrationIntentConflict
  | FederationRegistrationCompletionConflict
  | FederationRegistrationBootstrapIntentConflict
  | FederationRegistrationBootstrapStageConflict
  | FederationRegistrationBootstrapNotCompleted
  deriving stock (Eq, Show)

newFederationRegistrationState
  :: ChildBootstrapDeliveryIntent
  -> Either FederationRegistrationError FederationRegistrationState
newFederationRegistrationState intent =
  FederationBootstrapPrepared <$> validateChildBootstrapDeliveryIntent intent

applyFederationRegistrationCommand
  :: FederationRegistrationState
  -> FederationRegistrationCommand
  -> Either FederationRegistrationError FederationRegistrationState
applyFederationRegistrationCommand state command = case command of
  PrepareFederationBootstrap supplied ->
    if registrationStateBootstrapIntent state == supplied
      then Right state
      else Left FederationRegistrationBootstrapIntentConflict
  RecordFederationChildRecipient supplied -> do
    valid <- validateChildBootstrapRecipientAttestation supplied
    requireSameIntent state (childBootstrapRecipientIntent valid)
    case state of
      FederationBootstrapPrepared _ -> Right (FederationChildRecipientRecorded valid)
      FederationChildRecipientRecorded current | current == valid -> Right state
      FederationParentEnvelopeRecorded current
        | parentBootstrapEnvelopeChildRecipient current == valid -> Right state
      FederationChildDeliveryRecorded current
        | parentBootstrapEnvelopeChildRecipient (childBootstrapDeliveryParentEnvelope current) == valid ->
            Right state
      FederationBootstrapCustodyCompleted current
        | parentBootstrapEnvelopeChildRecipient
            (childBootstrapDeliveryParentEnvelope (parentBootstrapCustodyChildDelivery current))
            == valid ->
            Right state
      FederationRegistrationPrepared current
        | nestedChildRecipient (federationRegistrationBootstrapCustody current) == valid -> Right state
      FederationRegistrationCompleted current
        | nestedChildRecipient
            (federationRegistrationBootstrapCustody (federationRegistrationCompletedIntent current))
            == valid ->
            Right state
      _ -> Left FederationRegistrationBootstrapStageConflict
  RecordFederationParentEnvelope supplied -> do
    valid <- validateParentBootstrapEnvelope supplied
    requireSameIntent
      state
      (childBootstrapRecipientIntent (parentBootstrapEnvelopeChildRecipient valid))
    case state of
      FederationChildRecipientRecorded current
        | current == parentBootstrapEnvelopeChildRecipient valid ->
            Right (FederationParentEnvelopeRecorded valid)
      FederationParentEnvelopeRecorded current | current == valid -> Right state
      FederationChildDeliveryRecorded current
        | childBootstrapDeliveryParentEnvelope current == valid -> Right state
      FederationBootstrapCustodyCompleted current
        | childBootstrapDeliveryParentEnvelope (parentBootstrapCustodyChildDelivery current) == valid ->
            Right state
      FederationRegistrationPrepared current
        | nestedParentEnvelope (federationRegistrationBootstrapCustody current) == valid -> Right state
      FederationRegistrationCompleted current
        | nestedParentEnvelope
            (federationRegistrationBootstrapCustody (federationRegistrationCompletedIntent current))
            == valid ->
            Right state
      _ -> Left FederationRegistrationBootstrapStageConflict
  RecordFederationChildDelivery supplied -> do
    valid <- validateChildBootstrapDeliveryReceipt supplied
    requireSameIntent
      state
      ( childBootstrapRecipientIntent
          (parentBootstrapEnvelopeChildRecipient (childBootstrapDeliveryParentEnvelope valid))
      )
    case state of
      FederationParentEnvelopeRecorded current
        | current == childBootstrapDeliveryParentEnvelope valid ->
            Right (FederationChildDeliveryRecorded valid)
      FederationChildDeliveryRecorded current | current == valid -> Right state
      FederationBootstrapCustodyCompleted current
        | parentBootstrapCustodyChildDelivery current == valid -> Right state
      FederationRegistrationPrepared current
        | parentBootstrapCustodyChildDelivery (federationRegistrationBootstrapCustody current) == valid ->
            Right state
      FederationRegistrationCompleted current
        | parentBootstrapCustodyChildDelivery
            (federationRegistrationBootstrapCustody (federationRegistrationCompletedIntent current))
            == valid ->
            Right state
      _ -> Left FederationRegistrationBootstrapStageConflict
  CompleteFederationBootstrapCustody supplied -> do
    valid <- validateParentBootstrapCustodyReceipt supplied
    requireSameIntent state (bootstrapCustodyIntent valid)
    case state of
      FederationChildDeliveryRecorded current
        | current == parentBootstrapCustodyChildDelivery valid ->
            Right (FederationBootstrapCustodyCompleted valid)
      FederationBootstrapCustodyCompleted current | current == valid -> Right state
      FederationRegistrationPrepared current
        | federationRegistrationBootstrapCustody current == valid -> Right state
      FederationRegistrationCompleted current
        | federationRegistrationBootstrapCustody (federationRegistrationCompletedIntent current) == valid ->
            Right state
      _ -> Left FederationRegistrationBootstrapStageConflict
  PrepareFederationRegistration supplied -> do
    valid <- validateFederationRegistrationIntent supplied
    requireSameIntent state (bootstrapCustodyIntent (federationRegistrationBootstrapCustody valid))
    case state of
      FederationBootstrapCustodyCompleted current
        | current == federationRegistrationBootstrapCustody valid ->
            Right (FederationRegistrationPrepared valid)
      FederationRegistrationPrepared current | current == valid -> Right state
      FederationRegistrationCompleted current
        | federationRegistrationCompletedIntent current == valid -> Right state
      _ -> Left FederationRegistrationBootstrapNotCompleted
  CompleteFederationRegistration supplied -> do
    valid <- validateFederationRegistrationCompletion supplied
    case state of
      FederationRegistrationPrepared current
        | current == federationRegistrationCompletedIntent valid ->
            Right (FederationRegistrationCompleted valid)
      FederationRegistrationCompleted current | current == valid -> Right state
      _ -> Left FederationRegistrationCompletionConflict

requireSameIntent
  :: FederationRegistrationState
  -> ChildBootstrapDeliveryIntent
  -> Either FederationRegistrationError ()
requireSameIntent state supplied
  | registrationStateBootstrapIntent state == supplied = Right ()
  | otherwise = Left FederationRegistrationBootstrapIntentConflict

registrationStateBootstrapIntent
  :: FederationRegistrationState -> ChildBootstrapDeliveryIntent
registrationStateBootstrapIntent state = case state of
  FederationBootstrapPrepared intent -> intent
  FederationChildRecipientRecorded value -> childBootstrapRecipientIntent value
  FederationParentEnvelopeRecorded value ->
    childBootstrapRecipientIntent (parentBootstrapEnvelopeChildRecipient value)
  FederationChildDeliveryRecorded value ->
    childBootstrapRecipientIntent
      (parentBootstrapEnvelopeChildRecipient (childBootstrapDeliveryParentEnvelope value))
  FederationBootstrapCustodyCompleted value -> bootstrapCustodyIntent value
  FederationRegistrationPrepared value ->
    bootstrapCustodyIntent (federationRegistrationBootstrapCustody value)
  FederationRegistrationCompleted value ->
    bootstrapCustodyIntent
      (federationRegistrationBootstrapCustody (federationRegistrationCompletedIntent value))

registrationStateChildRecipient
  :: FederationRegistrationState -> Maybe ChildBootstrapRecipientAttestation
registrationStateChildRecipient state = case state of
  FederationBootstrapPrepared _ -> Nothing
  FederationChildRecipientRecorded value -> Just value
  FederationParentEnvelopeRecorded value -> Just (parentBootstrapEnvelopeChildRecipient value)
  FederationChildDeliveryRecorded value -> Just (parentBootstrapEnvelopeChildRecipient (childBootstrapDeliveryParentEnvelope value))
  FederationBootstrapCustodyCompleted value -> Just (nestedChildRecipient value)
  FederationRegistrationPrepared value -> Just (nestedChildRecipient (federationRegistrationBootstrapCustody value))
  FederationRegistrationCompleted value ->
    Just
      ( nestedChildRecipient
          (federationRegistrationBootstrapCustody (federationRegistrationCompletedIntent value))
      )

registrationStateParentEnvelope
  :: FederationRegistrationState -> Maybe ParentBootstrapEnvelope
registrationStateParentEnvelope state = case state of
  FederationBootstrapPrepared _ -> Nothing
  FederationChildRecipientRecorded _ -> Nothing
  FederationParentEnvelopeRecorded value -> Just value
  FederationChildDeliveryRecorded value -> Just (childBootstrapDeliveryParentEnvelope value)
  FederationBootstrapCustodyCompleted value -> Just (nestedParentEnvelope value)
  FederationRegistrationPrepared value -> Just (nestedParentEnvelope (federationRegistrationBootstrapCustody value))
  FederationRegistrationCompleted value ->
    Just
      ( nestedParentEnvelope
          (federationRegistrationBootstrapCustody (federationRegistrationCompletedIntent value))
      )

registrationStateChildDelivery
  :: FederationRegistrationState -> Maybe ChildBootstrapDeliveryReceipt
registrationStateChildDelivery state = case state of
  FederationBootstrapPrepared _ -> Nothing
  FederationChildRecipientRecorded _ -> Nothing
  FederationParentEnvelopeRecorded _ -> Nothing
  FederationChildDeliveryRecorded value -> Just value
  FederationBootstrapCustodyCompleted value -> Just (parentBootstrapCustodyChildDelivery value)
  FederationRegistrationPrepared value -> Just (parentBootstrapCustodyChildDelivery (federationRegistrationBootstrapCustody value))
  FederationRegistrationCompleted value ->
    Just
      ( parentBootstrapCustodyChildDelivery
          (federationRegistrationBootstrapCustody (federationRegistrationCompletedIntent value))
      )

registrationStateBootstrapCustody
  :: FederationRegistrationState -> Maybe ParentBootstrapCustodyReceipt
registrationStateBootstrapCustody state = case state of
  FederationBootstrapPrepared _ -> Nothing
  FederationChildRecipientRecorded _ -> Nothing
  FederationParentEnvelopeRecorded _ -> Nothing
  FederationChildDeliveryRecorded _ -> Nothing
  FederationBootstrapCustodyCompleted value -> Just value
  FederationRegistrationPrepared value -> Just (federationRegistrationBootstrapCustody value)
  FederationRegistrationCompleted value -> Just (federationRegistrationBootstrapCustody (federationRegistrationCompletedIntent value))

registrationStateCustodyIntent
  :: FederationRegistrationState -> Maybe FederationRegistrationIntent
registrationStateCustodyIntent state = case state of
  FederationRegistrationPrepared value -> Just value
  FederationRegistrationCompleted value -> Just (federationRegistrationCompletedIntent value)
  _ -> Nothing

registrationStateCompletion
  :: FederationRegistrationState -> Maybe FederationRegistrationCompletion
registrationStateCompletion state = case state of
  FederationRegistrationCompleted value -> Just value
  _ -> Nothing

nestedChildRecipient
  :: ParentBootstrapCustodyReceipt -> ChildBootstrapRecipientAttestation
nestedChildRecipient =
  parentBootstrapEnvelopeChildRecipient
    . childBootstrapDeliveryParentEnvelope
    . parentBootstrapCustodyChildDelivery

nestedParentEnvelope
  :: ParentBootstrapCustodyReceipt -> ParentBootstrapEnvelope
nestedParentEnvelope =
  childBootstrapDeliveryParentEnvelope . parentBootstrapCustodyChildDelivery

validateWorkerForIntent
  :: Bool
  -> ChildBootstrapDeliveryIntent
  -> FederationWorkerBinding
  -> Either FederationRegistrationError ()
validateWorkerForIntent parentSide intent worker =
  if federationWorkerCluster worker == expectedCluster
    && federationWorkerRolloutDigest worker == expectedRollout
    && federationWorkerServiceAccount worker == expectedServiceAccount
    then Right ()
    else Left FederationRegistrationWorkerSubstitution
 where
  expectedCluster =
    if parentSide
      then childBootstrapDeliveryParentCluster intent
      else childBootstrapDeliveryChildCluster intent
  expectedRollout =
    if parentSide
      then childBootstrapDeliveryParentWorkerRollout intent
      else childBootstrapDeliveryChildWorkerRollout intent
  expectedServiceAccount =
    if parentSide
      then childBootstrapDeliveryParentWorkerServiceAccount intent
      else childBootstrapDeliveryChildWorkerServiceAccount intent

validatePublicKey :: ByteString -> Either FederationRegistrationError ()
validatePublicKey bytes
  | ByteString.length bytes /= 32 = Left FederationRegistrationPublicKeyInvalid
  | otherwise = Right ()

validateCiphertext :: ByteString -> Either FederationRegistrationError ()
validateCiphertext bytes
  | ByteString.null bytes = Left FederationRegistrationCiphertextInvalid
  | ByteString.length bytes > 1024 * 1024 = Left FederationRegistrationCiphertextInvalid
  | otherwise = Right ()

validateClusterIdentity :: Text -> Either FederationRegistrationError Text
validateClusterIdentity =
  mapLeftRegistration FederationRegistrationParentClusterInvalid
    . validateTokenText "parent cluster identity" 128

validateChildClusterIdentity :: Text -> Either FederationRegistrationError Text
validateChildClusterIdentity =
  mapLeftRegistration FederationRegistrationChildClusterInvalid
    . validateTokenText "child cluster identity" 128

bounded
  :: FederationRegistrationError
  -> Int
  -> Text
  -> Either FederationRegistrationError Text
bounded failure maximumLength =
  mapLeftRegistration failure . validateTokenText "federation value" maximumLength

validateTokenText :: Text -> Int -> Text -> Either Text Text
validateTokenText label maximumLength raw
  | Text.null value = Left (label <> " must not be empty")
  | Text.length value > maximumLength = Left (label <> " is too long")
  | Text.any (\character -> isControl character || isSpace character) value =
      Left (label <> " contains whitespace or a control character")
  | otherwise = Right value
 where
  value = Text.strip raw

validateParentAuthorityEndpoint
  :: Text -> Either FederationRegistrationError Text
validateParentAuthorityEndpoint raw = do
  endpoint <- bounded FederationRegistrationParentAuthorityEndpointInvalid 2048 raw
  let authority = Text.takeWhile (/= '/') (Text.drop 8 endpoint)
      lowered = Text.toLower authority
      localAuthority =
        lowered == "localhost"
          || "localhost:" `Text.isPrefixOf` lowered
          || "127." `Text.isPrefixOf` lowered
          || "[::1]" `Text.isPrefixOf` lowered
          || ".svc" `Text.isSuffixOf` lowered
          || ".svc.cluster.local" `Text.isInfixOf` lowered
  if not ("https://" `Text.isPrefixOf` endpoint)
    || Text.null authority
    || Text.any (== '@') authority
    || localAuthority
    then Left FederationRegistrationParentAuthorityEndpointInvalid
    else Right endpoint

digestBytes :: Text -> ByteString -> ArtifactDigest
digestBytes domain bytes = digestSerialised (domain, bytes)

digestSerialised :: (Serialise value) => value -> ArtifactDigest
digestSerialised value =
  case mkArtifactDigest (lowerHexBytes (SHA256.hash bytes)) of
    Left failure -> error ("SHA-256 violated ArtifactDigest: " ++ show failure)
    Right digest -> digest
 where
  bytes = LazyByteString.toStrict (serialise value)

lowerHexBytes :: ByteString -> Text
lowerHexBytes = TextEncoding.decodeUtf8 . ByteString.concatMap renderByte
 where
  renderByte :: Word8 -> ByteString
  renderByte byte =
    TextEncoding.encodeUtf8
      (Text.pack (case showHex byte "" of [digit] -> ['0', digit]; digits -> digits))

mapLeftRegistration
  :: FederationRegistrationError
  -> Either error value
  -> Either FederationRegistrationError value
mapLeftRegistration failure = either (const (Left failure)) Right
