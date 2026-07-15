{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Sprint 1.61: the opaque writer permit and the signed committed intent that
-- make raw external mutations unconstructable. The two mutation programs
-- ('Prodbox.ControlPlane.Program.InternalCas' / 'ExternalCommit') require one of
-- these, and both are opaque with unexported constructors — a caller cannot mint
-- one directly:
--
--   * A 'WriterPermit' is minted only by 'authorizeInternalCas' from a fresh-Ready
--     'AdmissionTicket' whose coordinate matches the lease fence.
--   * A 'CommittedIntent' cannot exist without a signature ('signIntent'), and a
--     'VerifiedIntent' is minted only by 'verifyIntent' recomputing that HMAC.
--
-- Every artifact is bound to the coordinate digest of the reference that produced
-- the admission ticket, so a permit or intent for one coordinate can never drive
-- a write against another. The HMAC reuses the keyed-SHA-256 pattern the gateway
-- peer/continuity signatures already use.
module Prodbox.ControlPlane.Permit
  ( -- * Fence evidence
    FenceEvidence (..)

    -- * Internal-CAS writer permit
  , WriterPermit
  , permitCoordinateDigest
  , permitFence
  , permitGeneration
  , PermitRefusal (..)
  , authorizeInternalCas

    -- * External committed intent
  , ActionDigest (..)
  , IntentSignature (..)
  , IntentSigningKey (..)
  , IntentBinding (..)
  , IntentRefusal (..)
  , UnsignedIntent
  , CommittedIntent
  , VerifiedIntent
  , verifiedCoordinateDigest
  , verifiedBinding
  , prepareIntent
  , signIntent
  , verifyIntent
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.CapabilityKind
  ( CapabilityKind
  , ExternalIntentKind
  , InternalCasKind
  )
import Prodbox.ControlPlane.Coordinate
  ( AuthorityEpoch (AuthorityEpoch)
  , CoordinateDigest (CoordinateDigest)
  )
import Prodbox.ControlPlane.Observation
  ( AdmissionTicket
  , admissionCoordinateDigest
  , admissionGeneration
  )
import Prodbox.Lifecycle.CheckpointAuthority (ModelBObjectVersion, modelBObjectVersionText)
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , FencingToken
  , OwnerNonce
  , authorityTimeMicros
  , fencingTokenValue
  , ownerNonceText
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , credentialGenerationValue
  , targetValueDigestText
  )

-- | The lease fence a mutation is guarded by: the owner nonce, fencing token,
-- and object version the caller currently holds, plus the coordinate they are
-- for.
data FenceEvidence = FenceEvidence
  { fenceOwner :: !OwnerNonce
  , fenceToken :: !FencingToken
  , fenceVersion :: !ModelBObjectVersion
  , fenceDigest :: !CoordinateDigest
  }
  deriving (Eq, Show)

-- | The @nominal@ role keeps a permit bound to its operation.
type role WriterPermit nominal

data WriterPermit (k :: CapabilityKind) = MkWriterPermit
  { permitCoordinateDigest :: !CoordinateDigest
  , permitFence :: !FenceEvidence
  , permitGeneration :: !CredentialGeneration
  }

data PermitRefusal
  = -- | The ticket and the fence are for different coordinates (ticket, fence).
    PermitCoordinateMismatch !CoordinateDigest !CoordinateDigest
  | -- | The ticket's generation is older than the required one (ticket, required).
    PermitGenerationStale !CredentialGeneration !CredentialGeneration
  deriving (Eq, Show)

-- | The sole 'WriterPermit' producer. An internal-CAS kind's fresh-Ready ticket
-- plus a lease fence for the SAME coordinate at a non-stale generation mints a
-- permit; a coordinate or generation mismatch is refused.
authorizeInternalCas
  :: (InternalCasKind k)
  => CredentialGeneration
  -> AdmissionTicket k
  -> FenceEvidence
  -> Either PermitRefusal (WriterPermit k)
authorizeInternalCas requiredGeneration ticket fence
  | admissionCoordinateDigest ticket /= fenceDigest fence =
      Left (PermitCoordinateMismatch (admissionCoordinateDigest ticket) (fenceDigest fence))
  | admissionGeneration ticket < requiredGeneration =
      Left (PermitGenerationStale (admissionGeneration ticket) requiredGeneration)
  | otherwise =
      Right
        ( MkWriterPermit
            (admissionCoordinateDigest ticket)
            fence
            (admissionGeneration ticket)
        )

-- | Digest of the exact external action a committed intent authorizes.
newtype ActionDigest = ActionDigest TargetValueDigest
  deriving (Eq, Show)

newtype IntentSignature = IntentSignature ByteString
  deriving (Eq, Show)

-- | The symmetric key the committed-intent HMAC is keyed by (follow-on: unify
-- with the Vault-derived gateway event key).
newtype IntentSigningKey = IntentSigningKey ByteString

-- | What an external intent binds: the authority epoch, the lease fence, the
-- action digest, the credential generation, and the absolute deadline.
data IntentBinding = IntentBinding
  { bindEpoch :: !AuthorityEpoch
  , bindFence :: !FenceEvidence
  , bindAction :: !ActionDigest
  , bindGen :: !CredentialGeneration
  , bindDeadline :: !AuthorityTime
  }
  deriving (Eq, Show)

data IntentRefusal
  = IntentCoordinateMismatch
  | IntentDeadlineReached !AuthorityTime !AuthorityTime
  | IntentGenerationStale
  | IntentSignatureInvalid
  deriving (Eq, Show)

type role UnsignedIntent nominal
data UnsignedIntent (k :: CapabilityKind) = MkUnsignedIntent
  { unsignedDigest :: !CoordinateDigest
  , unsignedBinding :: !IntentBinding
  }

type role CommittedIntent nominal
data CommittedIntent (k :: CapabilityKind) = MkCommittedIntent
  { committedUnsigned :: !(UnsignedIntent k)
  , committedSignature :: !IntentSignature
  }

type role VerifiedIntent nominal
data VerifiedIntent (k :: CapabilityKind) = MkVerifiedIntent
  { verifiedCoordinateDigest :: !CoordinateDigest
  , verifiedBinding :: !IntentBinding
  }

-- | Prepare an unsigned external intent from an external-intent kind's fresh-Ready
-- ticket. Refuses on a coordinate mismatch, a reached deadline, or a stale
-- generation; the ticket's coordinate becomes the intent's coordinate.
prepareIntent
  :: (ExternalIntentKind k)
  => AuthorityTime
  -> CredentialGeneration
  -> AdmissionTicket k
  -> IntentBinding
  -> Either IntentRefusal (UnsignedIntent k)
prepareIntent now requiredGeneration ticket binding
  | admissionCoordinateDigest ticket /= fenceDigest (bindFence binding) =
      Left IntentCoordinateMismatch
  | authorityTimeMicros now >= authorityTimeMicros (bindDeadline binding) =
      Left (IntentDeadlineReached now (bindDeadline binding))
  | admissionGeneration ticket < requiredGeneration =
      Left IntentGenerationStale
  | otherwise = Right (MkUnsignedIntent (admissionCoordinateDigest ticket) binding)

-- | The sole 'CommittedIntent' producer: HMAC the canonical wire form.
signIntent :: IntentSigningKey -> UnsignedIntent k -> CommittedIntent k
signIntent (IntentSigningKey key) unsigned =
  MkCommittedIntent unsigned (IntentSignature (SHA256.hmac key (canonicalUnsignedBytes unsigned)))

-- | The sole 'VerifiedIntent' producer: recompute the HMAC and compare. Only a
-- matching signature yields a verified intent.
verifyIntent :: IntentSigningKey -> CommittedIntent k -> Either IntentRefusal (VerifiedIntent k)
verifyIntent (IntentSigningKey key) committed
  | SHA256.hmac key (canonicalUnsignedBytes unsigned) == expected =
      Right (MkVerifiedIntent (unsignedDigest unsigned) (unsignedBinding unsigned))
  | otherwise = Left IntentSignatureInvalid
 where
  unsigned = committedUnsigned committed
  IntentSignature expected = committedSignature committed

-- | The canonical byte encoding an intent's HMAC is computed over: a NUL-joined,
-- injective encoding of the coordinate digest and every binding field.
canonicalUnsignedBytes :: UnsignedIntent k -> ByteString
canonicalUnsignedBytes unsigned =
  TextEncoding.encodeUtf8
    ( Text.intercalate
        "\NUL"
        [ digestText (unsignedDigest unsigned)
        , Text.pack (show epochValue)
        , ownerNonceText (fenceOwner fence)
        , Text.pack (show (fencingTokenValue (fenceToken fence)))
        , modelBObjectVersionText (fenceVersion fence)
        , digestText' (bindAction binding)
        , Text.pack (show (credentialGenerationValue (bindGen binding)))
        , Text.pack (show (authorityTimeMicros (bindDeadline binding)))
        ]
    )
 where
  binding = unsignedBinding unsigned
  fence = bindFence binding
  AuthorityEpoch epochValue = bindEpoch binding
  digestText (CoordinateDigest value) = targetValueDigestText value
  digestText' (ActionDigest value) = targetValueDigestText value
