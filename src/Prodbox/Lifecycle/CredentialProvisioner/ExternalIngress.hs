{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Secret-free, retained Lifecycle Authority state for the one-shot ACME EAB
-- ingress.  Plaintext EAB fields are deliberately absent from every type in
-- this module: the Authority commits an intent, exact Pod attestation, signed
-- delivery permit, and opaque one-shot custody/target read-back receipt only.
module Prodbox.Lifecycle.CredentialProvisioner.ExternalIngress
  ( ExternalMaterialIngressIntent
  , ExternalMaterialIngressIntentError (..)
  , mkExternalMaterialIngressIntent
  , externalMaterialIngressIntentRequest
  , externalMaterialIngressIntentPermitId
  , externalMaterialIngressIntentImageDigest
  , externalMaterialIngressIntentDeadline
  , externalMaterialIngressJobIntent
  , ExternalMaterialJobBinding
  , ExternalMaterialJobBindingError (..)
  , mkExternalMaterialJobBinding
  , externalMaterialJobUid
  , externalMaterialJobPodUid
  , externalMaterialJobServiceAccountUid
  , SignedExternalAcmeEabPermit
  , ExternalMaterialPermitError (..)
  , externalMaterialPermitSigningPayload
  , mkSignedExternalAcmeEabPermit
  , verifySignedExternalAcmeEabPermit
  , encodeSignedExternalAcmeEabPermit
  , decodeSignedExternalAcmeEabPermit
  , signedExternalMaterialPermitId
  , signedExternalMaterialRequestDigest
  , signedExternalMaterialGeneration
  , signedExternalMaterialDeadline
  , signedExternalMaterialJobBinding
  , withSignedExternalOperatorPermit
  , ExternalMaterialTargetReceipt
  , ExternalMaterialTargetReceiptError (..)
  , mkExternalMaterialTargetReceipt
  , externalMaterialTargetReceiptPermitId
  , externalMaterialTargetReceiptRequestDigest
  , externalMaterialTargetReceiptGeneration
  , externalMaterialTargetReceiptCommitment
  , externalMaterialTargetReceiptCiphertextDigest
  , externalMaterialTargetReceiptReadBackVersion
  , externalMaterialTargetReceiptDigest
  , encodeExternalMaterialTargetReceipt
  , decodeExternalMaterialTargetReceipt
  , ExternalMaterialIngressPhase (..)
  , ExternalMaterialIngressState
  , initialExternalMaterialIngressState
  , externalMaterialIngressPhase
  , externalMaterialIngressCurrentIntent
  , externalMaterialIngressCurrentPermit
  , externalMaterialIngressCurrentReceipt
  , ExternalMaterialIngressTransitionError (..)
  , commitExternalMaterialIngressIntent
  , commitExternalMaterialJobBinding
  , commitExternalMaterialSignedPermit
  , commitExternalMaterialTargetReceipt
  , ExternalMaterialIngressCodecError (..)
  , externalMaterialIngressStateCodec
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.Hash.SHA256 qualified as SHA256
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.CheckpointAuthority (ModelBCodec (..))
import Prodbox.Lifecycle.CredentialProvisioner.Kubernetes
  ( CredentialProvisionerImageDigest
  , CredentialProvisionerJobIntent
  , credentialProvisionerImageDigestText
  , credentialProvisionerIntentServiceAccount
  , credentialProvisionerJobName
  , credentialProvisionerServiceAccountText
  , mkCredentialProvisionerImageDigest
  , mkExternalCredentialProvisionerJobIntent
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( OperatorMaterialAction (..)
  , OperatorMaterialIngressSchema (ExternalAcmeEabIngress)
  , OperatorMaterialOperationId
  , OperatorMaterialPermit
  , OperatorMaterialPermitId
  , OperatorMaterialRequest
  , SOperatorMaterialIngressSchema (SExternalAcmeEabIngress)
  , SomeOperatorMaterialRequest (SomeOperatorMaterialRequest)
  , decodeOperatorMaterialRequest
  , encodeOperatorMaterialRequest
  , mkExternalAcmeEabRequest
  , mkOperatorMaterialPermit
  , mkOperatorMaterialPermitId
  , operatorMaterialPermitIdText
  , operatorMaterialRequestAction
  , operatorMaterialRequestDigest
  , operatorMaterialRequestGeneration
  , operatorMaterialRequestOperationId
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetValueDigest
  , targetValueDigestText
  )

data ExternalMaterialIngressIntent = ExternalMaterialIngressIntent
  { internalExternalIntentRequest
      :: !(OperatorMaterialRequest 'ExternalAcmeEabIngress)
  , internalExternalIntentPermitId :: !OperatorMaterialPermitId
  , internalExternalIntentImageDigest :: !CredentialProvisionerImageDigest
  , internalExternalIntentDeadline :: !AuthorityTime
  }
  deriving stock (Eq, Show)

data ExternalMaterialIngressIntentError
  = ExternalMaterialIngressRevocationRequiresDecommission
  | ExternalMaterialIngressDeadlineInvalid
  deriving stock (Eq, Show)

mkExternalMaterialIngressIntent
  :: OperatorMaterialAction
  -> OperatorMaterialOperationId
  -> CredentialGeneration
  -> OperatorMaterialPermitId
  -> CredentialProvisionerImageDigest
  -> AuthorityTime
  -> Either ExternalMaterialIngressIntentError ExternalMaterialIngressIntent
mkExternalMaterialIngressIntent action operationId generation permitId imageDigest deadline = do
  when
    (action == RevokeOperatorMaterial)
    (Left ExternalMaterialIngressRevocationRequiresDecommission)
  when
    (authorityTimeMicros deadline == 0)
    (Left ExternalMaterialIngressDeadlineInvalid)
  pure
    ExternalMaterialIngressIntent
      { internalExternalIntentRequest =
          mkExternalAcmeEabRequest action operationId generation
      , internalExternalIntentPermitId = permitId
      , internalExternalIntentImageDigest = imageDigest
      , internalExternalIntentDeadline = deadline
      }

externalMaterialIngressIntentRequest
  :: ExternalMaterialIngressIntent
  -> OperatorMaterialRequest 'ExternalAcmeEabIngress
externalMaterialIngressIntentRequest = internalExternalIntentRequest

externalMaterialIngressIntentPermitId
  :: ExternalMaterialIngressIntent -> OperatorMaterialPermitId
externalMaterialIngressIntentPermitId = internalExternalIntentPermitId

externalMaterialIngressIntentImageDigest
  :: ExternalMaterialIngressIntent -> CredentialProvisionerImageDigest
externalMaterialIngressIntentImageDigest = internalExternalIntentImageDigest

externalMaterialIngressIntentDeadline
  :: ExternalMaterialIngressIntent -> AuthorityTime
externalMaterialIngressIntentDeadline = internalExternalIntentDeadline

externalMaterialIngressJobIntent
  :: ExternalMaterialIngressIntent
  -> CredentialProvisionerJobIntent 'ExternalAcmeEabIngress
externalMaterialIngressJobIntent intent =
  mkExternalCredentialProvisionerJobIntent
    (externalMaterialIngressIntentImageDigest intent)
    (externalMaterialIngressIntentPermitId intent)
    (operatorMaterialRequestDigest (externalMaterialIngressIntentRequest intent))
    (externalMaterialIngressIntentDeadline intent)

data ExternalMaterialJobBinding = ExternalMaterialJobBinding
  { internalExternalJobName :: !Text
  , internalExternalJobUid :: !Text
  , internalExternalJobPodUid :: !Text
  , internalExternalJobImageDigest :: !Text
  , internalExternalJobServiceAccount :: !Text
  , internalExternalJobServiceAccountUid :: !Text
  , internalExternalJobHeartbeatMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ExternalMaterialJobBindingError
  = ExternalMaterialJobBindingFieldEmpty !Text
  | ExternalMaterialJobBindingFieldTooLong !Text !Int !Int
  | ExternalMaterialJobBindingHeartbeatInvalid
  deriving stock (Eq, Show)

mkExternalMaterialJobBinding
  :: Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Natural
  -> Either ExternalMaterialJobBindingError ExternalMaterialJobBinding
mkExternalMaterialJobBinding
  jobName
  jobUid
  podUid
  imageDigest
  serviceAccount
  serviceAccountUid
  heartbeat = do
    validJob <- validateBindingField "job name" 253 jobName
    validJobUid <- validateBindingField "Job UID" 256 jobUid
    validPodUid <- validateBindingField "Pod UID" 256 podUid
    validImage <- validateBindingField "image digest" 256 imageDigest
    validServiceAccount <- validateBindingField "ServiceAccount" 253 serviceAccount
    validServiceAccountUid <-
      validateBindingField "ServiceAccount UID" 256 serviceAccountUid
    when (heartbeat == 0) (Left ExternalMaterialJobBindingHeartbeatInvalid)
    pure
      ExternalMaterialJobBinding
        { internalExternalJobName = validJob
        , internalExternalJobUid = validJobUid
        , internalExternalJobPodUid = validPodUid
        , internalExternalJobImageDigest = validImage
        , internalExternalJobServiceAccount = validServiceAccount
        , internalExternalJobServiceAccountUid = validServiceAccountUid
        , internalExternalJobHeartbeatMicros = heartbeat
        }

externalMaterialJobUid :: ExternalMaterialJobBinding -> Text
externalMaterialJobUid = internalExternalJobUid

externalMaterialJobPodUid :: ExternalMaterialJobBinding -> Text
externalMaterialJobPodUid = internalExternalJobPodUid

externalMaterialJobServiceAccountUid :: ExternalMaterialJobBinding -> Text
externalMaterialJobServiceAccountUid = internalExternalJobServiceAccountUid

validateBindingField
  :: Text -> Int -> Text -> Either ExternalMaterialJobBindingError Text
validateBindingField label maximumLength raw
  | Text.null value = Left (ExternalMaterialJobBindingFieldEmpty label)
  | Text.length value > maximumLength =
      Left (ExternalMaterialJobBindingFieldTooLong label (Text.length value) maximumLength)
  | otherwise = Right value
 where
  value = Text.strip raw

data SignedExternalAcmeEabPermit = SignedExternalAcmeEabPermit
  { internalSignedExternalPermitVersion :: !Word16
  , internalSignedExternalPermitId :: !Text
  , internalSignedExternalRequest :: !ByteString
  , internalSignedExternalDeadlineMicros :: !Natural
  , internalSignedExternalJobBinding :: !ExternalMaterialJobBinding
  , internalSignedExternalSignature :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ExternalMaterialPermitError
  = ExternalMaterialPermitRequestInvalid
  | ExternalMaterialPermitSchemaMismatch
  | ExternalMaterialPermitIdentifierInvalid
  | ExternalMaterialPermitSignatureEmpty
  | ExternalMaterialPermitSignatureInvalid
  | ExternalMaterialPermitPublicKeyInvalid
  | ExternalMaterialPermitExpired
  | ExternalMaterialPermitUnsupportedVersion !Word16
  | ExternalMaterialPermitTooLarge !Int !Int
  | ExternalMaterialPermitDecodeFailed
  | ExternalMaterialPermitNonCanonical
  | ExternalMaterialPermitJobBindingMismatch
  deriving stock (Eq, Show)

externalMaterialPermitVersion :: Word16
externalMaterialPermitVersion = 1

externalMaterialPermitMaximumBytes :: Int
externalMaterialPermitMaximumBytes = 32 * 1024

data ExternalMaterialPermitSigningEnvelope = ExternalMaterialPermitSigningEnvelope
  { externalSigningDomain :: !Text
  , externalSigningVersion :: !Word16
  , externalSigningPermitId :: !Text
  , externalSigningRequest :: !ByteString
  , externalSigningDeadlineMicros :: !Natural
  , externalSigningJobBinding :: !ExternalMaterialJobBinding
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

externalMaterialPermitSigningPayload
  :: ExternalMaterialIngressIntent -> ExternalMaterialJobBinding -> ByteString
externalMaterialPermitSigningPayload intent binding =
  LazyByteString.toStrict
    ( serialise
        ExternalMaterialPermitSigningEnvelope
          { externalSigningDomain = "prodbox-external-acme-eab-permit-v1"
          , externalSigningVersion = externalMaterialPermitVersion
          , externalSigningPermitId =
              operatorMaterialPermitIdText
                (externalMaterialIngressIntentPermitId intent)
          , externalSigningRequest =
              encodeOperatorMaterialRequest
                (externalMaterialIngressIntentRequest intent)
          , externalSigningDeadlineMicros =
              authorityTimeMicros (externalMaterialIngressIntentDeadline intent)
          , externalSigningJobBinding = binding
          }
    )

mkSignedExternalAcmeEabPermit
  :: ExternalMaterialIngressIntent
  -> ExternalMaterialJobBinding
  -> ByteString
  -> Either ExternalMaterialPermitError SignedExternalAcmeEabPermit
mkSignedExternalAcmeEabPermit intent binding signature = do
  when (ByteString.null signature) (Left ExternalMaterialPermitSignatureEmpty)
  when
    (ByteString.length signature > 512)
    (Left ExternalMaterialPermitSignatureInvalid)
  validateBindingMatchesIntent intent binding
  pure
    SignedExternalAcmeEabPermit
      { internalSignedExternalPermitVersion = externalMaterialPermitVersion
      , internalSignedExternalPermitId =
          operatorMaterialPermitIdText (externalMaterialIngressIntentPermitId intent)
      , internalSignedExternalRequest =
          encodeOperatorMaterialRequest (externalMaterialIngressIntentRequest intent)
      , internalSignedExternalDeadlineMicros =
          authorityTimeMicros (externalMaterialIngressIntentDeadline intent)
      , internalSignedExternalJobBinding = binding
      , internalSignedExternalSignature = signature
      }

verifySignedExternalAcmeEabPermit
  :: ByteString
  -> AuthorityTime
  -> SignedExternalAcmeEabPermit
  -> Either ExternalMaterialPermitError ()
verifySignedExternalAcmeEabPermit publicBytes now permit = do
  intent <- permitIntent permit
  validateBindingMatchesIntent intent (internalSignedExternalJobBinding permit)
  when
    (authorityTimeMicros now >= internalSignedExternalDeadlineMicros permit)
    (Left ExternalMaterialPermitExpired)
  publicKey <- case Ed25519.publicKey publicBytes of
    CryptoFailed _ -> Left ExternalMaterialPermitPublicKeyInvalid
    CryptoPassed key -> Right key
  signature <- case Ed25519.signature (internalSignedExternalSignature permit) of
    CryptoFailed _ -> Left ExternalMaterialPermitSignatureInvalid
    CryptoPassed value -> Right value
  unless
    ( Ed25519.verify
        publicKey
        ( externalMaterialPermitSigningPayload
            intent
            (internalSignedExternalJobBinding permit)
        )
        signature
    )
    (Left ExternalMaterialPermitSignatureInvalid)

encodeSignedExternalAcmeEabPermit :: SignedExternalAcmeEabPermit -> ByteString
encodeSignedExternalAcmeEabPermit = LazyByteString.toStrict . serialise

decodeSignedExternalAcmeEabPermit
  :: ByteString -> Either ExternalMaterialPermitError SignedExternalAcmeEabPermit
decodeSignedExternalAcmeEabPermit bytes
  | ByteString.length bytes > externalMaterialPermitMaximumBytes =
      Left
        ( ExternalMaterialPermitTooLarge
            (ByteString.length bytes)
            externalMaterialPermitMaximumBytes
        )
  | otherwise = do
      permit <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left ExternalMaterialPermitDecodeFailed
        Right decoded -> Right decoded
      when
        (internalSignedExternalPermitVersion permit /= externalMaterialPermitVersion)
        ( Left
            ( ExternalMaterialPermitUnsupportedVersion
                (internalSignedExternalPermitVersion permit)
            )
        )
      when
        (encodeSignedExternalAcmeEabPermit permit /= bytes)
        (Left ExternalMaterialPermitNonCanonical)
      intent <- permitIntent permit
      validateBindingMatchesIntent intent (internalSignedExternalJobBinding permit)
      when
        (ByteString.null (internalSignedExternalSignature permit))
        (Left ExternalMaterialPermitSignatureEmpty)
      pure permit

permitIntent
  :: SignedExternalAcmeEabPermit
  -> Either ExternalMaterialPermitError ExternalMaterialIngressIntent
permitIntent permit = do
  request <- case decodeOperatorMaterialRequest (internalSignedExternalRequest permit) of
    Left _ -> Left ExternalMaterialPermitRequestInvalid
    Right (SomeOperatorMaterialRequest SExternalAcmeEabIngress decoded) -> Right decoded
    Right _ -> Left ExternalMaterialPermitSchemaMismatch
  permitId <-
    either
      (const (Left ExternalMaterialPermitIdentifierInvalid))
      Right
      (mkOperatorMaterialPermitId (internalSignedExternalPermitId permit))
  imageDigest <-
    either
      (const (Left ExternalMaterialPermitJobBindingMismatch))
      Right
      (mkCredentialProvisionerImageDigest (internalExternalJobImageDigest binding))
  either
    (const (Left ExternalMaterialPermitRequestInvalid))
    Right
    ( mkExternalMaterialIngressIntent
        (operatorMaterialRequestAction request)
        (operatorMaterialRequestOperationId request)
        (operatorMaterialRequestGeneration request)
        permitId
        imageDigest
        (authorityTimeFromMicros (internalSignedExternalDeadlineMicros permit))
    )
 where
  binding = internalSignedExternalJobBinding permit

validateBindingMatchesIntent
  :: ExternalMaterialIngressIntent
  -> ExternalMaterialJobBinding
  -> Either ExternalMaterialPermitError ()
validateBindingMatchesIntent intent binding = do
  let jobIntent = externalMaterialIngressJobIntent intent
      expectedName = credentialProvisionerJobName jobIntent
      expectedImage =
        credentialProvisionerImageDigestText
          (externalMaterialIngressIntentImageDigest intent)
      expectedServiceAccount =
        credentialProvisionerServiceAccountText
          (credentialProvisionerIntentServiceAccount jobIntent)
  validatedBinding <-
    either
      (const (Left ExternalMaterialPermitJobBindingMismatch))
      Right
      ( mkExternalMaterialJobBinding
          (internalExternalJobName binding)
          (internalExternalJobUid binding)
          (internalExternalJobPodUid binding)
          (internalExternalJobImageDigest binding)
          (internalExternalJobServiceAccount binding)
          (internalExternalJobServiceAccountUid binding)
          (internalExternalJobHeartbeatMicros binding)
      )
  unless
    ( validatedBinding == binding
        && internalExternalJobName binding == expectedName
        && internalExternalJobImageDigest binding == expectedImage
        && internalExternalJobServiceAccount binding == expectedServiceAccount
        && internalExternalJobHeartbeatMicros binding
          < authorityTimeMicros (externalMaterialIngressIntentDeadline intent)
    )
    (Left ExternalMaterialPermitJobBindingMismatch)

signedExternalMaterialPermitId
  :: SignedExternalAcmeEabPermit -> OperatorMaterialPermitId
signedExternalMaterialPermitId permit =
  case mkOperatorMaterialPermitId (internalSignedExternalPermitId permit) of
    Left _ -> error "validated external material permit ID invariant violated"
    Right value -> value

signedExternalMaterialRequestDigest
  :: SignedExternalAcmeEabPermit -> TargetValueDigest
signedExternalMaterialRequestDigest permit =
  operatorMaterialRequestDigest (externalPermitRequest permit)

signedExternalMaterialGeneration
  :: SignedExternalAcmeEabPermit -> CredentialGeneration
signedExternalMaterialGeneration =
  operatorMaterialRequestGeneration . externalPermitRequest

signedExternalMaterialDeadline :: SignedExternalAcmeEabPermit -> AuthorityTime
signedExternalMaterialDeadline =
  authorityTimeFromMicros . internalSignedExternalDeadlineMicros

signedExternalMaterialJobBinding
  :: SignedExternalAcmeEabPermit -> ExternalMaterialJobBinding
signedExternalMaterialJobBinding = internalSignedExternalJobBinding

externalPermitRequest
  :: SignedExternalAcmeEabPermit
  -> OperatorMaterialRequest 'ExternalAcmeEabIngress
externalPermitRequest permit =
  case permitIntent permit of
    Left _ -> error "validated external material permit request invariant violated"
    Right intent -> externalMaterialIngressIntentRequest intent

withSignedExternalOperatorPermit
  :: SignedExternalAcmeEabPermit
  -> (OperatorMaterialPermit 'ExternalAcmeEabIngress -> result)
  -> Either ExternalMaterialPermitError result
withSignedExternalOperatorPermit signed consume = do
  intent <- permitIntent signed
  permit <-
    either
      (const (Left ExternalMaterialPermitRequestInvalid))
      Right
      ( mkOperatorMaterialPermit
          (externalMaterialIngressIntentPermitId intent)
          (externalMaterialIngressIntentRequest intent)
          (externalMaterialIngressIntentDeadline intent)
          Nothing
          (internalSignedExternalSignature signed)
      )
  pure (consume permit)

data ExternalMaterialTargetReceipt = ExternalMaterialTargetReceipt
  { internalExternalReceiptPermitId :: !Text
  , internalExternalReceiptRequestDigest :: !Text
  , internalExternalReceiptGeneration :: !Natural
  , internalExternalReceiptCommitment :: !Text
  , internalExternalReceiptCiphertextDigest :: !Text
  , internalExternalReceiptReadBackVersion :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ExternalMaterialTargetReceiptError
  = ExternalMaterialTargetReceiptPermitMismatch
  | ExternalMaterialTargetReceiptDigestMismatch
  | ExternalMaterialTargetReceiptGenerationMismatch
  | ExternalMaterialTargetReceiptCommitmentInvalid
  | ExternalMaterialTargetReceiptCiphertextDigestInvalid
  | ExternalMaterialTargetReceiptVersionInvalid
  | ExternalMaterialTargetReceiptTooLarge !Int !Int
  | ExternalMaterialTargetReceiptDecodeFailed
  | ExternalMaterialTargetReceiptNonCanonical
  deriving stock (Eq, Show)

mkExternalMaterialTargetReceipt
  :: SignedExternalAcmeEabPermit
  -> Text
  -> Text
  -> Natural
  -> Either ExternalMaterialTargetReceiptError ExternalMaterialTargetReceipt
mkExternalMaterialTargetReceipt permit commitment ciphertextDigest readBackVersion = do
  validCommitment <-
    maybe
      (Left ExternalMaterialTargetReceiptCommitmentInvalid)
      Right
      (validatedVaultHmac commitment)
  validCiphertextDigest <-
    maybe
      (Left ExternalMaterialTargetReceiptCiphertextDigestInvalid)
      Right
      (validatedOpaqueCommitment ciphertextDigest)
  when
    (readBackVersion == 0)
    (Left ExternalMaterialTargetReceiptVersionInvalid)
  pure
    ExternalMaterialTargetReceipt
      { internalExternalReceiptPermitId =
          operatorMaterialPermitIdText (signedExternalMaterialPermitId permit)
      , internalExternalReceiptRequestDigest =
          targetValueDigestText (signedExternalMaterialRequestDigest permit)
      , internalExternalReceiptGeneration =
          credentialGenerationValue (signedExternalMaterialGeneration permit)
      , internalExternalReceiptCommitment = validCommitment
      , internalExternalReceiptCiphertextDigest = validCiphertextDigest
      , internalExternalReceiptReadBackVersion = readBackVersion
      }

externalMaterialTargetReceiptPermitId
  :: ExternalMaterialTargetReceipt -> OperatorMaterialPermitId
externalMaterialTargetReceiptPermitId receipt =
  case mkOperatorMaterialPermitId (internalExternalReceiptPermitId receipt) of
    Left _ -> error "validated external material receipt permit invariant violated"
    Right permitId -> permitId

externalMaterialTargetReceiptRequestDigest
  :: ExternalMaterialTargetReceipt -> TargetValueDigest
externalMaterialTargetReceiptRequestDigest receipt =
  case mkTargetValueDigest (internalExternalReceiptRequestDigest receipt) of
    Left _ -> error "validated external material receipt digest invariant violated"
    Right digest -> digest

externalMaterialTargetReceiptGeneration
  :: ExternalMaterialTargetReceipt -> CredentialGeneration
externalMaterialTargetReceiptGeneration receipt =
  case mkCredentialGeneration (internalExternalReceiptGeneration receipt) of
    Left _ -> error "validated external material receipt generation invariant violated"
    Right generation -> generation

externalMaterialTargetReceiptCommitment
  :: ExternalMaterialTargetReceipt -> Text
externalMaterialTargetReceiptCommitment = internalExternalReceiptCommitment

externalMaterialTargetReceiptCiphertextDigest
  :: ExternalMaterialTargetReceipt -> TargetValueDigest
externalMaterialTargetReceiptCiphertextDigest receipt =
  case mkTargetValueDigest (internalExternalReceiptCiphertextDigest receipt) of
    Left _ -> error "validated external material ciphertext digest invariant violated"
    Right digest -> digest

externalMaterialTargetReceiptReadBackVersion
  :: ExternalMaterialTargetReceipt -> Natural
externalMaterialTargetReceiptReadBackVersion =
  internalExternalReceiptReadBackVersion

externalMaterialTargetReceiptDigest
  :: ExternalMaterialTargetReceipt -> TargetValueDigest
externalMaterialTargetReceiptDigest =
  digestBytes . LazyByteString.toStrict . serialise

encodeExternalMaterialTargetReceipt :: ExternalMaterialTargetReceipt -> ByteString
encodeExternalMaterialTargetReceipt = LazyByteString.toStrict . serialise

decodeExternalMaterialTargetReceipt
  :: ByteString
  -> Either ExternalMaterialTargetReceiptError ExternalMaterialTargetReceipt
decodeExternalMaterialTargetReceipt bytes
  | ByteString.length bytes > receiptMaximumBytes =
      Left
        ( ExternalMaterialTargetReceiptTooLarge
            (ByteString.length bytes)
            receiptMaximumBytes
        )
  | otherwise = do
      receipt <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left ExternalMaterialTargetReceiptDecodeFailed
        Right value -> Right value
      when
        (encodeExternalMaterialTargetReceipt receipt /= bytes)
        (Left ExternalMaterialTargetReceiptNonCanonical)
      when
        (internalExternalReceiptReadBackVersion receipt == 0)
        (Left ExternalMaterialTargetReceiptVersionInvalid)
      _ <-
        maybe
          (Left ExternalMaterialTargetReceiptCommitmentInvalid)
          Right
          (validatedVaultHmac (internalExternalReceiptCommitment receipt))
      _ <-
        maybe
          (Left ExternalMaterialTargetReceiptCiphertextDigestInvalid)
          Right
          (validatedOpaqueCommitment (internalExternalReceiptCiphertextDigest receipt))
      _ <-
        either
          (const (Left ExternalMaterialTargetReceiptPermitMismatch))
          Right
          (mkOperatorMaterialPermitId (internalExternalReceiptPermitId receipt))
      _ <-
        either
          (const (Left ExternalMaterialTargetReceiptDigestMismatch))
          Right
          (mkTargetValueDigest (internalExternalReceiptRequestDigest receipt))
      _ <-
        either
          (const (Left ExternalMaterialTargetReceiptGenerationMismatch))
          Right
          (mkCredentialGeneration (internalExternalReceiptGeneration receipt))
      pure receipt
 where
  receiptMaximumBytes = 4096

data ExternalMaterialIngressPhase
  = ExternalMaterialIngressIdle
  | ExternalMaterialIngressIntentCommitted
  | ExternalMaterialIngressAttestationCommitted
  | ExternalMaterialIngressPermitCommitted
  | ExternalMaterialIngressReceiptCommitted
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (Serialise)

data ExternalMaterialIngressState
  = ExternalIngressIdle
  | ExternalIngressIntent !ExternalMaterialIngressIntent
  | ExternalIngressAttested
      !ExternalMaterialIngressIntent
      !ExternalMaterialJobBinding
  | ExternalIngressPermitted
      !ExternalMaterialIngressIntent
      !ExternalMaterialJobBinding
      !SignedExternalAcmeEabPermit
  | ExternalIngressCompleted
      !ExternalMaterialIngressIntent
      !ExternalMaterialJobBinding
      !SignedExternalAcmeEabPermit
      !ExternalMaterialTargetReceipt
  deriving stock (Eq, Show)

initialExternalMaterialIngressState :: ExternalMaterialIngressState
initialExternalMaterialIngressState = ExternalIngressIdle

externalMaterialIngressPhase
  :: ExternalMaterialIngressState -> ExternalMaterialIngressPhase
externalMaterialIngressPhase state = case state of
  ExternalIngressIdle -> ExternalMaterialIngressIdle
  ExternalIngressIntent {} -> ExternalMaterialIngressIntentCommitted
  ExternalIngressAttested {} -> ExternalMaterialIngressAttestationCommitted
  ExternalIngressPermitted {} -> ExternalMaterialIngressPermitCommitted
  ExternalIngressCompleted {} -> ExternalMaterialIngressReceiptCommitted

externalMaterialIngressCurrentIntent
  :: ExternalMaterialIngressState -> Maybe ExternalMaterialIngressIntent
externalMaterialIngressCurrentIntent state = case state of
  ExternalIngressIdle -> Nothing
  ExternalIngressIntent intent -> Just intent
  ExternalIngressAttested intent _ -> Just intent
  ExternalIngressPermitted intent _ _ -> Just intent
  ExternalIngressCompleted intent _ _ _ -> Just intent

externalMaterialIngressCurrentPermit
  :: ExternalMaterialIngressState -> Maybe SignedExternalAcmeEabPermit
externalMaterialIngressCurrentPermit state = case state of
  ExternalIngressPermitted _ _ permit -> Just permit
  ExternalIngressCompleted _ _ permit _ -> Just permit
  _ -> Nothing

externalMaterialIngressCurrentReceipt
  :: ExternalMaterialIngressState -> Maybe ExternalMaterialTargetReceipt
externalMaterialIngressCurrentReceipt state = case state of
  ExternalIngressCompleted _ _ _ receipt -> Just receipt
  _ -> Nothing

data ExternalMaterialIngressTransitionError
  = ExternalMaterialIngressActiveConflict
  | ExternalMaterialIngressFirstActionMustInstall
  | ExternalMaterialIngressFirstGenerationMustBeOne
  | ExternalMaterialIngressRotationActionRequired
  | ExternalMaterialIngressGenerationNotSuccessor
  | ExternalMaterialIngressIntentMismatch
  | ExternalMaterialIngressAttestationMismatch
  | ExternalMaterialIngressPermitMismatch
  | ExternalMaterialIngressReceiptMismatch
  | ExternalMaterialIngressTransitionOutOfOrder
  deriving stock (Eq, Show)

commitExternalMaterialIngressIntent
  :: ExternalMaterialIngressIntent
  -> ExternalMaterialIngressState
  -> Either ExternalMaterialIngressTransitionError ExternalMaterialIngressState
commitExternalMaterialIngressIntent intent state = case state of
  ExternalIngressIdle -> do
    unless
      (operatorMaterialRequestAction request == InstallOperatorMaterial)
      (Left ExternalMaterialIngressFirstActionMustInstall)
    unless
      (credentialGenerationValue (operatorMaterialRequestGeneration request) == 1)
      (Left ExternalMaterialIngressFirstGenerationMustBeOne)
    pure (ExternalIngressIntent intent)
  ExternalIngressCompleted previousIntent _ _ _
    | previousIntent == intent -> Right state
    | otherwise -> do
        unless
          (operatorMaterialRequestAction request == RotateOperatorMaterial)
          (Left ExternalMaterialIngressRotationActionRequired)
        unless
          ( credentialGenerationValue (operatorMaterialRequestGeneration request)
              == credentialGenerationValue
                (operatorMaterialRequestGeneration (externalMaterialIngressIntentRequest previousIntent))
                + 1
          )
          (Left ExternalMaterialIngressGenerationNotSuccessor)
        pure (ExternalIngressIntent intent)
  _
    | externalMaterialIngressCurrentIntent state == Just intent -> Right state
    | otherwise -> Left ExternalMaterialIngressActiveConflict
 where
  request = externalMaterialIngressIntentRequest intent

commitExternalMaterialJobBinding
  :: ExternalMaterialIngressIntent
  -> ExternalMaterialJobBinding
  -> ExternalMaterialIngressState
  -> Either ExternalMaterialIngressTransitionError ExternalMaterialIngressState
commitExternalMaterialJobBinding intent binding state = case state of
  ExternalIngressIntent current
    | current == intent -> Right (ExternalIngressAttested intent binding)
    | otherwise -> Left ExternalMaterialIngressIntentMismatch
  ExternalIngressAttested current existing
    | current == intent && existing == binding -> Right state
    | current /= intent -> Left ExternalMaterialIngressIntentMismatch
    | otherwise -> Left ExternalMaterialIngressAttestationMismatch
  ExternalIngressPermitted current existing _
    | current == intent && existing == binding -> Right state
  ExternalIngressCompleted current existing _ _
    | current == intent && existing == binding -> Right state
  _ -> Left ExternalMaterialIngressTransitionOutOfOrder

commitExternalMaterialSignedPermit
  :: ExternalMaterialIngressIntent
  -> ExternalMaterialJobBinding
  -> SignedExternalAcmeEabPermit
  -> ExternalMaterialIngressState
  -> Either ExternalMaterialIngressTransitionError ExternalMaterialIngressState
commitExternalMaterialSignedPermit intent binding permit state = case state of
  ExternalIngressAttested current currentBinding
    | current /= intent -> Left ExternalMaterialIngressIntentMismatch
    | currentBinding /= binding -> Left ExternalMaterialIngressAttestationMismatch
    | permitMatches intent binding permit ->
        Right (ExternalIngressPermitted intent binding permit)
    | otherwise -> Left ExternalMaterialIngressPermitMismatch
  ExternalIngressPermitted current currentBinding existing
    | current == intent && currentBinding == binding && existing == permit -> Right state
    | otherwise -> Left ExternalMaterialIngressPermitMismatch
  ExternalIngressCompleted current currentBinding existing _
    | current == intent && currentBinding == binding && existing == permit -> Right state
    | otherwise -> Left ExternalMaterialIngressPermitMismatch
  _ -> Left ExternalMaterialIngressTransitionOutOfOrder

commitExternalMaterialTargetReceipt
  :: SignedExternalAcmeEabPermit
  -> ExternalMaterialTargetReceipt
  -> ExternalMaterialIngressState
  -> Either ExternalMaterialIngressTransitionError ExternalMaterialIngressState
commitExternalMaterialTargetReceipt permit receipt state = case state of
  ExternalIngressPermitted intent binding currentPermit
    | currentPermit /= permit -> Left ExternalMaterialIngressPermitMismatch
    | receiptMatches permit receipt ->
        Right (ExternalIngressCompleted intent binding permit receipt)
    | otherwise -> Left ExternalMaterialIngressReceiptMismatch
  ExternalIngressCompleted _ _ currentPermit currentReceipt
    | currentPermit == permit && currentReceipt == receipt -> Right state
    | otherwise -> Left ExternalMaterialIngressReceiptMismatch
  _ -> Left ExternalMaterialIngressTransitionOutOfOrder

permitMatches
  :: ExternalMaterialIngressIntent
  -> ExternalMaterialJobBinding
  -> SignedExternalAcmeEabPermit
  -> Bool
permitMatches intent binding permit =
  internalSignedExternalPermitId permit
    == operatorMaterialPermitIdText (externalMaterialIngressIntentPermitId intent)
    && internalSignedExternalRequest permit
      == encodeOperatorMaterialRequest (externalMaterialIngressIntentRequest intent)
    && internalSignedExternalDeadlineMicros permit
      == authorityTimeMicros (externalMaterialIngressIntentDeadline intent)
    && internalSignedExternalJobBinding permit == binding

receiptMatches
  :: SignedExternalAcmeEabPermit -> ExternalMaterialTargetReceipt -> Bool
receiptMatches permit receipt =
  internalExternalReceiptPermitId receipt
    == operatorMaterialPermitIdText (signedExternalMaterialPermitId permit)
    && internalExternalReceiptRequestDigest receipt
      == targetValueDigestText (signedExternalMaterialRequestDigest permit)
    && internalExternalReceiptGeneration receipt
      == credentialGenerationValue (signedExternalMaterialGeneration permit)
    && validatedVaultHmac (internalExternalReceiptCommitment receipt)
      == Just (internalExternalReceiptCommitment receipt)
    && validatedOpaqueCommitment (internalExternalReceiptCiphertextDigest receipt)
      == Just (internalExternalReceiptCiphertextDigest receipt)
    && internalExternalReceiptReadBackVersion receipt > 0

validatedOpaqueCommitment :: Text -> Maybe Text
validatedOpaqueCommitment raw =
  case mkTargetValueDigest value of
    Left _ -> Nothing
    Right _ -> Just value
 where
  value = Text.strip raw

validatedVaultHmac :: Text -> Maybe Text
validatedVaultHmac raw
  | "vault:v" `Text.isPrefixOf` value
  , Text.length value <= 512
  , not (Text.any (`elem` [' ', '\n', '\r', '\t']) value) =
      Just value
  | otherwise = Nothing
 where
  value = Text.strip raw

data ExternalMaterialIngressStateEnvelope = ExternalMaterialIngressStateEnvelope
  { externalStateEnvelopeVersion :: !Word16
  , externalStateEnvelopePhase :: !ExternalMaterialIngressPhase
  , externalStateEnvelopeIntent :: !(Maybe WireExternalMaterialIntent)
  , externalStateEnvelopeBinding :: !(Maybe ExternalMaterialJobBinding)
  , externalStateEnvelopePermit :: !(Maybe SignedExternalAcmeEabPermit)
  , externalStateEnvelopeReceipt :: !(Maybe ExternalMaterialTargetReceipt)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireExternalMaterialIntent = WireExternalMaterialIntent
  { wireExternalIntentRequest :: !ByteString
  , wireExternalIntentPermitId :: !Text
  , wireExternalIntentImageDigest :: !Text
  , wireExternalIntentDeadlineMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ExternalMaterialIngressCodecError
  = ExternalMaterialIngressCodecTooLarge !Int !Int
  | ExternalMaterialIngressCodecDecodeFailed
  | ExternalMaterialIngressCodecUnsupportedVersion !Word16
  | ExternalMaterialIngressCodecNonCanonical
  | ExternalMaterialIngressCodecInvalidState
  deriving stock (Eq, Show)

externalMaterialIngressStateCodec
  :: Int -> ModelBCodec ExternalMaterialIngressState
externalMaterialIngressStateCodec maximumBytes =
  ModelBCodec
    { encodeModelBValue = \state ->
        let bytes = LazyByteString.toStrict (serialise (stateToEnvelope state))
         in if ByteString.length bytes > maximumBytes
              then
                Left
                  ( show
                      ( ExternalMaterialIngressCodecTooLarge
                          (ByteString.length bytes)
                          maximumBytes
                      )
                  )
              else Right bytes
    , decodeModelBValue = \bytes ->
        mapLeft show (decodeState bytes)
    }
 where
  decodeState bytes
    | ByteString.length bytes > maximumBytes =
        Left
          ( ExternalMaterialIngressCodecTooLarge
              (ByteString.length bytes)
              maximumBytes
          )
    | otherwise = do
        envelope <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
          Left _ -> Left ExternalMaterialIngressCodecDecodeFailed
          Right decoded -> Right decoded
        when
          (externalStateEnvelopeVersion envelope /= externalMaterialStateVersion)
          ( Left
              ( ExternalMaterialIngressCodecUnsupportedVersion
                  (externalStateEnvelopeVersion envelope)
              )
          )
        when
          (LazyByteString.toStrict (serialise envelope) /= bytes)
          (Left ExternalMaterialIngressCodecNonCanonical)
        envelopeToState envelope

externalMaterialStateVersion :: Word16
externalMaterialStateVersion = 2

stateToEnvelope
  :: ExternalMaterialIngressState -> ExternalMaterialIngressStateEnvelope
stateToEnvelope state = case state of
  ExternalIngressIdle -> envelope ExternalMaterialIngressIdle Nothing Nothing Nothing Nothing
  ExternalIngressIntent intent ->
    envelope ExternalMaterialIngressIntentCommitted (Just (intentToWire intent)) Nothing Nothing Nothing
  ExternalIngressAttested intent binding ->
    envelope
      ExternalMaterialIngressAttestationCommitted
      (Just (intentToWire intent))
      (Just binding)
      Nothing
      Nothing
  ExternalIngressPermitted intent binding permit ->
    envelope
      ExternalMaterialIngressPermitCommitted
      (Just (intentToWire intent))
      (Just binding)
      (Just permit)
      Nothing
  ExternalIngressCompleted intent binding permit receipt ->
    envelope
      ExternalMaterialIngressReceiptCommitted
      (Just (intentToWire intent))
      (Just binding)
      (Just permit)
      (Just receipt)
 where
  envelope phase intent binding permit receipt =
    ExternalMaterialIngressStateEnvelope
      { externalStateEnvelopeVersion = externalMaterialStateVersion
      , externalStateEnvelopePhase = phase
      , externalStateEnvelopeIntent = intent
      , externalStateEnvelopeBinding = binding
      , externalStateEnvelopePermit = permit
      , externalStateEnvelopeReceipt = receipt
      }

intentToWire :: ExternalMaterialIngressIntent -> WireExternalMaterialIntent
intentToWire intent =
  WireExternalMaterialIntent
    { wireExternalIntentRequest =
        encodeOperatorMaterialRequest (externalMaterialIngressIntentRequest intent)
    , wireExternalIntentPermitId =
        operatorMaterialPermitIdText (externalMaterialIngressIntentPermitId intent)
    , wireExternalIntentImageDigest =
        credentialProvisionerImageDigestText
          (externalMaterialIngressIntentImageDigest intent)
    , wireExternalIntentDeadlineMicros =
        authorityTimeMicros (externalMaterialIngressIntentDeadline intent)
    }

intentFromWire
  :: WireExternalMaterialIntent
  -> Either ExternalMaterialIngressCodecError ExternalMaterialIngressIntent
intentFromWire wire = do
  request <- case decodeOperatorMaterialRequest (wireExternalIntentRequest wire) of
    Right (SomeOperatorMaterialRequest SExternalAcmeEabIngress value) -> Right value
    _ -> Left ExternalMaterialIngressCodecInvalidState
  permitId <-
    mapInvalid (mkOperatorMaterialPermitId (wireExternalIntentPermitId wire))
  imageDigest <-
    mapInvalid (mkCredentialProvisionerImageDigest (wireExternalIntentImageDigest wire))
  mapInvalid
    ( mkExternalMaterialIngressIntent
        (operatorMaterialRequestAction request)
        (operatorMaterialRequestOperationId request)
        (operatorMaterialRequestGeneration request)
        permitId
        imageDigest
        (authorityTimeFromMicros (wireExternalIntentDeadlineMicros wire))
    )
 where
  mapInvalid = either (const (Left ExternalMaterialIngressCodecInvalidState)) Right

envelopeToState
  :: ExternalMaterialIngressStateEnvelope
  -> Either ExternalMaterialIngressCodecError ExternalMaterialIngressState
envelopeToState envelope = case ( externalStateEnvelopePhase envelope
                                , externalStateEnvelopeIntent envelope
                                , externalStateEnvelopeBinding envelope
                                , externalStateEnvelopePermit envelope
                                , externalStateEnvelopeReceipt envelope
                                ) of
  (ExternalMaterialIngressIdle, Nothing, Nothing, Nothing, Nothing) ->
    Right ExternalIngressIdle
  (ExternalMaterialIngressIntentCommitted, Just wire, Nothing, Nothing, Nothing) ->
    ExternalIngressIntent <$> intentFromWire wire
  (ExternalMaterialIngressAttestationCommitted, Just wire, Just binding, Nothing, Nothing) -> do
    intent <- intentFromWire wire
    mapTransition (commitExternalMaterialJobBinding intent binding (ExternalIngressIntent intent))
  (ExternalMaterialIngressPermitCommitted, Just wire, Just binding, Just permit, Nothing) -> do
    intent <- intentFromWire wire
    attested <-
      mapTransition (commitExternalMaterialJobBinding intent binding (ExternalIngressIntent intent))
    mapTransition (commitExternalMaterialSignedPermit intent binding permit attested)
  (ExternalMaterialIngressReceiptCommitted, Just wire, Just binding, Just permit, Just receipt) -> do
    intent <- intentFromWire wire
    attested <-
      mapTransition (commitExternalMaterialJobBinding intent binding (ExternalIngressIntent intent))
    permitted <- mapTransition (commitExternalMaterialSignedPermit intent binding permit attested)
    mapTransition (commitExternalMaterialTargetReceipt permit receipt permitted)
  _ -> Left ExternalMaterialIngressCodecInvalidState
 where
  mapTransition = either (const (Left ExternalMaterialIngressCodecInvalidState)) Right

digestBytes :: ByteString -> TargetValueDigest
digestBytes bytes =
  let rendered = Text.pack (concatMap renderOctet (ByteString.unpack (SHA256.hash bytes)))
   in case mkTargetValueDigest rendered of
        Left _ -> error "SHA-256 rendering invariant violated"
        Right digest -> digest
 where
  renderOctet byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft transform = either (Left . transform) Right
