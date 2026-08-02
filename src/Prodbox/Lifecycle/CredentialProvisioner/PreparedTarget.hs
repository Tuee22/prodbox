{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Secret-free Authority observation of the exact prepared target outbox.
-- This is committed before a Credential Provisioner permit is signed and is
-- itself embedded in the signature payload.  It fixes the destination Agent,
-- owner/fence, target, generation, request/receipt digests, plan cursor, and
-- deadline before administrator credentials enter the worker.
module Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
  ( PreparedCredentialTargetObservation
  , mkPreparedCredentialTargetObservation
  , preparedCredentialTargetOwnerNonce
  , preparedCredentialTargetFence
  , preparedCredentialTargetSelectedAgent
  , preparedCredentialTargetId
  , preparedCredentialTargetGeneration
  , preparedCredentialTargetRequestDigest
  , preparedCredentialTargetReceiptDigest
  , preparedCredentialTargetPlanBinding
  , preparedCredentialTargetDeadline
  , PreparedCredentialTargetError (..)
  , PreparedCredentialTargetCodecError (..)
  , encodePreparedCredentialTargetObservation
  , decodePreparedCredentialTargetObservation
  , preparedCredentialTargetObservationCodec
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.TargetMaterialRegistry (TargetSecretId)
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentIdentity
  , mkTargetAgentIdentity
  , targetAgentIdentityText
  )
import Prodbox.Lifecycle.CheckpointAuthority (ModelBCodec (..))
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( FirstReconcilePermitBinding
  , firstReconcilePermitMemberDigest
  , firstReconcilePermitMemberIndex
  , firstReconcilePermitPlanDigest
  , firstReconcilePermitPriorReceiptDigest
  , mkFirstReconcilePermitBinding
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

data PreparedCredentialTargetObservation = PreparedCredentialTargetObservation
  { internalPreparedCredentialTargetOwnerNonce :: !Text
  , internalPreparedCredentialTargetFence :: !Natural
  , internalPreparedCredentialTargetSelectedAgent :: !TargetAgentIdentity
  , internalPreparedCredentialTargetId :: !TargetSecretId
  , internalPreparedCredentialTargetGeneration :: !CredentialGeneration
  , internalPreparedCredentialTargetRequestDigest :: !TargetValueDigest
  , internalPreparedCredentialTargetReceiptDigest :: !TargetValueDigest
  , internalPreparedCredentialTargetPlanBinding :: !(Maybe FirstReconcilePermitBinding)
  , internalPreparedCredentialTargetDeadline :: !AuthorityTime
  }
  deriving stock (Eq, Show)

mkPreparedCredentialTargetObservation
  :: Text
  -> Natural
  -> TargetAgentIdentity
  -> TargetSecretId
  -> CredentialGeneration
  -> TargetValueDigest
  -> TargetValueDigest
  -> Maybe FirstReconcilePermitBinding
  -> AuthorityTime
  -> Either PreparedCredentialTargetError PreparedCredentialTargetObservation
mkPreparedCredentialTargetObservation ownerNonce fence selectedAgent target generation requestDigest receiptDigest planBinding deadline = do
  validOwner <- validateOwnerNonce ownerNonce
  if fence == 0
    then Left PreparedCredentialTargetFenceInvalid
    else Right ()
  if authorityTimeMicros deadline == 0
    then Left PreparedCredentialTargetDeadlineInvalid
    else Right ()
  pure
    PreparedCredentialTargetObservation
      { internalPreparedCredentialTargetOwnerNonce = validOwner
      , internalPreparedCredentialTargetFence = fence
      , internalPreparedCredentialTargetSelectedAgent = selectedAgent
      , internalPreparedCredentialTargetId = target
      , internalPreparedCredentialTargetGeneration = generation
      , internalPreparedCredentialTargetRequestDigest = requestDigest
      , internalPreparedCredentialTargetReceiptDigest = receiptDigest
      , internalPreparedCredentialTargetPlanBinding = planBinding
      , internalPreparedCredentialTargetDeadline = deadline
      }

preparedCredentialTargetOwnerNonce :: PreparedCredentialTargetObservation -> Text
preparedCredentialTargetOwnerNonce = internalPreparedCredentialTargetOwnerNonce

preparedCredentialTargetFence :: PreparedCredentialTargetObservation -> Natural
preparedCredentialTargetFence = internalPreparedCredentialTargetFence

preparedCredentialTargetSelectedAgent
  :: PreparedCredentialTargetObservation -> TargetAgentIdentity
preparedCredentialTargetSelectedAgent = internalPreparedCredentialTargetSelectedAgent

preparedCredentialTargetId :: PreparedCredentialTargetObservation -> TargetSecretId
preparedCredentialTargetId = internalPreparedCredentialTargetId

preparedCredentialTargetGeneration
  :: PreparedCredentialTargetObservation -> CredentialGeneration
preparedCredentialTargetGeneration = internalPreparedCredentialTargetGeneration

preparedCredentialTargetRequestDigest
  :: PreparedCredentialTargetObservation -> TargetValueDigest
preparedCredentialTargetRequestDigest = internalPreparedCredentialTargetRequestDigest

preparedCredentialTargetReceiptDigest
  :: PreparedCredentialTargetObservation -> TargetValueDigest
preparedCredentialTargetReceiptDigest = internalPreparedCredentialTargetReceiptDigest

preparedCredentialTargetPlanBinding
  :: PreparedCredentialTargetObservation -> Maybe FirstReconcilePermitBinding
preparedCredentialTargetPlanBinding = internalPreparedCredentialTargetPlanBinding

preparedCredentialTargetDeadline :: PreparedCredentialTargetObservation -> AuthorityTime
preparedCredentialTargetDeadline = internalPreparedCredentialTargetDeadline

validateOwnerNonce :: Text -> Either PreparedCredentialTargetError Text
validateOwnerNonce raw
  | Text.null value = Left PreparedCredentialTargetOwnerNonceInvalid
  | Text.length value > 256 = Left PreparedCredentialTargetOwnerNonceInvalid
  | Text.any (\character -> isControl character || isSpace character) value =
      Left PreparedCredentialTargetOwnerNonceInvalid
  | otherwise = Right value
 where
  value = Text.strip raw

data PreparedCredentialTargetError
  = PreparedCredentialTargetOwnerNonceInvalid
  | PreparedCredentialTargetFenceInvalid
  | PreparedCredentialTargetDeadlineInvalid
  deriving stock (Eq, Show)

data WireFirstReconcilePermitBinding = WireFirstReconcilePermitBinding
  { wirePreparedPlanDigest :: !Text
  , wirePreparedMemberIndex :: !Natural
  , wirePreparedMemberDigest :: !Text
  , wirePreparedPriorReceiptDigest :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WirePreparedCredentialTargetObservation = WirePreparedCredentialTargetObservation
  { wirePreparedTargetVersion :: !Word16
  , wirePreparedTargetOwnerNonce :: !Text
  , wirePreparedTargetFence :: !Natural
  , wirePreparedTargetSelectedAgent :: !Text
  , wirePreparedTargetId :: !TargetSecretId
  , wirePreparedTargetGeneration :: !Natural
  , wirePreparedTargetRequestDigest :: !Text
  , wirePreparedTargetReceiptDigest :: !Text
  , wirePreparedTargetPlanBinding :: !(Maybe WireFirstReconcilePermitBinding)
  , wirePreparedTargetDeadlineMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data PreparedCredentialTargetCodecError
  = PreparedCredentialTargetTooLarge !Int !Int
  | PreparedCredentialTargetDecodeFailed
  | PreparedCredentialTargetUnsupportedVersion !Word16
  | PreparedCredentialTargetValueInvalid !Text
  | PreparedCredentialTargetNonCanonical
  deriving stock (Eq, Show)

preparedCredentialTargetCodecVersion :: Word16
preparedCredentialTargetCodecVersion = 1

preparedCredentialTargetMaximumBytes :: Int
preparedCredentialTargetMaximumBytes = 32 * 1024

encodePreparedCredentialTargetObservation
  :: PreparedCredentialTargetObservation -> ByteString
encodePreparedCredentialTargetObservation =
  LazyByteString.toStrict . serialise . preparedTargetToWire

decodePreparedCredentialTargetObservation
  :: ByteString
  -> Either PreparedCredentialTargetCodecError PreparedCredentialTargetObservation
decodePreparedCredentialTargetObservation bytes = do
  when
    (ByteString.length bytes > preparedCredentialTargetMaximumBytes)
    ( Left
        ( PreparedCredentialTargetTooLarge
            (ByteString.length bytes)
            preparedCredentialTargetMaximumBytes
        )
    )
  wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
    Left _ -> Left PreparedCredentialTargetDecodeFailed
    Right value -> Right value
  unless
    (wirePreparedTargetVersion wire == preparedCredentialTargetCodecVersion)
    ( Left
        ( PreparedCredentialTargetUnsupportedVersion
            (wirePreparedTargetVersion wire)
        )
    )
  observation <- preparedTargetFromWire wire
  unless
    (encodePreparedCredentialTargetObservation observation == bytes)
    (Left PreparedCredentialTargetNonCanonical)
  pure observation

preparedCredentialTargetObservationCodec
  :: ModelBCodec PreparedCredentialTargetObservation
preparedCredentialTargetObservationCodec =
  ModelBCodec
    { encodeModelBValue = Right . encodePreparedCredentialTargetObservation
    , decodeModelBValue =
        first show . decodePreparedCredentialTargetObservation
    }

preparedTargetToWire
  :: PreparedCredentialTargetObservation
  -> WirePreparedCredentialTargetObservation
preparedTargetToWire prepared =
  WirePreparedCredentialTargetObservation
    { wirePreparedTargetVersion = preparedCredentialTargetCodecVersion
    , wirePreparedTargetOwnerNonce = preparedCredentialTargetOwnerNonce prepared
    , wirePreparedTargetFence = preparedCredentialTargetFence prepared
    , wirePreparedTargetSelectedAgent =
        targetAgentIdentityText (preparedCredentialTargetSelectedAgent prepared)
    , wirePreparedTargetId = preparedCredentialTargetId prepared
    , wirePreparedTargetGeneration =
        credentialGenerationValue (preparedCredentialTargetGeneration prepared)
    , wirePreparedTargetRequestDigest =
        targetValueDigestText (preparedCredentialTargetRequestDigest prepared)
    , wirePreparedTargetReceiptDigest =
        targetValueDigestText (preparedCredentialTargetReceiptDigest prepared)
    , wirePreparedTargetPlanBinding =
        planBindingToWire <$> preparedCredentialTargetPlanBinding prepared
    , wirePreparedTargetDeadlineMicros =
        authorityTimeMicros (preparedCredentialTargetDeadline prepared)
    }

preparedTargetFromWire
  :: WirePreparedCredentialTargetObservation
  -> Either PreparedCredentialTargetCodecError PreparedCredentialTargetObservation
preparedTargetFromWire wire = do
  selectedAgent <- value (mkTargetAgentIdentity (wirePreparedTargetSelectedAgent wire))
  generation <- value (mkCredentialGeneration (wirePreparedTargetGeneration wire))
  requestDigest <- value (mkTargetValueDigest (wirePreparedTargetRequestDigest wire))
  receiptDigest <- value (mkTargetValueDigest (wirePreparedTargetReceiptDigest wire))
  planBinding <- traverse planBindingFromWire (wirePreparedTargetPlanBinding wire)
  prepared <-
    value
      ( mkPreparedCredentialTargetObservation
          (wirePreparedTargetOwnerNonce wire)
          (wirePreparedTargetFence wire)
          selectedAgent
          (wirePreparedTargetId wire)
          generation
          requestDigest
          receiptDigest
          planBinding
          (authorityTimeFromMicros (wirePreparedTargetDeadlineMicros wire))
      )
  unless
    (preparedTargetToWire prepared == wire)
    (Left PreparedCredentialTargetNonCanonical)
  pure prepared
 where
  value
    :: (Show error)
    => Either error result
    -> Either PreparedCredentialTargetCodecError result
  value = first (PreparedCredentialTargetValueInvalid . Text.pack . show)

planBindingToWire
  :: FirstReconcilePermitBinding -> WireFirstReconcilePermitBinding
planBindingToWire binding =
  WireFirstReconcilePermitBinding
    { wirePreparedPlanDigest =
        targetValueDigestText (firstReconcilePermitPlanDigest binding)
    , wirePreparedMemberIndex = firstReconcilePermitMemberIndex binding
    , wirePreparedMemberDigest =
        targetValueDigestText (firstReconcilePermitMemberDigest binding)
    , wirePreparedPriorReceiptDigest =
        targetValueDigestText <$> firstReconcilePermitPriorReceiptDigest binding
    }

planBindingFromWire
  :: WireFirstReconcilePermitBinding
  -> Either PreparedCredentialTargetCodecError FirstReconcilePermitBinding
planBindingFromWire wire = do
  planDigest <- value (mkTargetValueDigest (wirePreparedPlanDigest wire))
  memberDigest <- value (mkTargetValueDigest (wirePreparedMemberDigest wire))
  priorReceipt <-
    traverse (value . mkTargetValueDigest) (wirePreparedPriorReceiptDigest wire)
  pure
    ( mkFirstReconcilePermitBinding
        planDigest
        (wirePreparedMemberIndex wire)
        memberDigest
        priorReceipt
    )
 where
  value
    :: (Show error)
    => Either error result
    -> Either PreparedCredentialTargetCodecError result
  value = first (PreparedCredentialTargetValueInvalid . Text.pack . show)
