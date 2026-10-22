{-# LANGUAGE OverloadedStrings #-}

-- | Validated public coordinates for the terminal audit's retained catalog.
-- This leaf is shared by the durable scope and the catalog, so recovery never
-- rebuilds the retained set from changed host configuration.
module Prodbox.Lifecycle.Teardown.RetainedNames
  ( RetainedNameBinding
  , retainedStateBucketName
  , retainedCaptureBucketName
  , retainedSenderDomain
  , retainedClusterTagName
  , RetainedBindingError (..)
  , mkRetainedNameBinding
  , mkOptionalRetainedNameBinding
  )
where

import Codec.CBOR.Decoding qualified as Cbor
import Codec.CBOR.Encoding qualified as Cbor
import Codec.Serialise (Serialise (..))
import Control.Monad (unless)
import Data.Char (isControl)
import Data.Text (Text)
import Data.Text qualified as Text

-- | The operator-configured names the retained set depends on.  The catalog
-- refuses to be built from raw text: every field passes 'mkRetainedNameBinding'
-- first, so a blank or whitespace-bearing value cannot compose an ARN that
-- silently matches nothing.
data RetainedNameBinding = RetainedNameBinding
  { internalStateBucketName :: !(Maybe Text)
  , internalCaptureBucketName :: !(Maybe Text)
  , internalSenderDomain :: !(Maybe Text)
  , internalClusterTagName :: !Text
  }
  deriving (Eq, Ord, Show)

retainedStateBucketName :: RetainedNameBinding -> Maybe Text
retainedStateBucketName = internalStateBucketName

retainedCaptureBucketName :: RetainedNameBinding -> Maybe Text
retainedCaptureBucketName = internalCaptureBucketName

retainedSenderDomain :: RetainedNameBinding -> Maybe Text
retainedSenderDomain = internalSenderDomain

retainedClusterTagName :: RetainedNameBinding -> Text
retainedClusterTagName = internalClusterTagName

data RetainedBindingError
  = RetainedBindingFieldEmpty !Text
  | RetainedBindingFieldNotCanonical !Text !Text
  deriving (Eq, Show)

-- | Build the binding.  Field names are carried in the error so a
-- configuration defect names the field it came from.
mkRetainedNameBinding
  :: Text
  -- ^ @pulumi_state_backend.bucket_name@
  -> Text
  -- ^ @ses.capture_bucket@
  -> Text
  -- ^ @ses.sender_domain@
  -> Text
  -- ^ the per-run EKS cluster name used by the ownership tag query
  -> Either RetainedBindingError RetainedNameBinding
mkRetainedNameBinding stateBucket captureBucket senderDomain =
  mkOptionalRetainedNameBinding (Just stateBucket) (Just captureBucket) (Just senderDomain)

-- | Nothing records an authored unset coordinate, not an observation of
-- absence. Such a name contributes no retention matcher; an old tagged
-- resource outside the configured retained set is therefore still an escape.
mkOptionalRetainedNameBinding
  :: Maybe Text -> Maybe Text -> Maybe Text -> Text -> Either RetainedBindingError RetainedNameBinding
mkOptionalRetainedNameBinding stateBucket captureBucket senderDomain clusterName = do
  state <- traverse (canonicalField "pulumi_state_backend.bucket_name") stateBucket
  capture <- traverse (canonicalField "ses.capture_bucket") captureBucket
  domain <- traverse (canonicalField "ses.sender_domain") senderDomain
  cluster <- canonicalField "aws-eks.cluster_name" clusterName
  Right (RetainedNameBinding state capture domain cluster)

canonicalField :: Text -> Text -> Either RetainedBindingError Text
canonicalField field raw
  | Text.null raw = Left (RetainedBindingFieldEmpty field)
  | Text.length raw > 512 || Text.any isControl raw =
      Left (RetainedBindingFieldNotCanonical field raw)
  | raw /= Text.strip raw = Left (RetainedBindingFieldNotCanonical field raw)
  | Text.any (`elem` (" \t\r\n\NUL" :: String)) raw =
      Left (RetainedBindingFieldNotCanonical field raw)
  | otherwise = Right raw

instance Serialise RetainedNameBinding where
  encode binding = case (retainedStateBucketName binding, retainedCaptureBucketName binding, retainedSenderDomain binding) of
    (Just state, Just capture, Just domain) ->
      Cbor.encodeListLen 5
        <> Cbor.encodeWord 0
        <> encode state
        <> encode capture
        <> encode domain
        <> encode (retainedClusterTagName binding)
    _ ->
      Cbor.encodeListLen 5
        <> Cbor.encodeWord 1
        <> encode (retainedStateBucketName binding)
        <> encode (retainedCaptureBucketName binding)
        <> encode (retainedSenderDomain binding)
        <> encode (retainedClusterTagName binding)
  decode = do
    count <- Cbor.decodeListLen
    tag <- Cbor.decodeWord
    unless (count == 5) (fail "retained audit names field count")
    case (tag :: Word) of
      0 -> do
        state <- decode
        capture <- decode
        domain <- decode
        cluster <- decode
        either (fail . show) pure (mkRetainedNameBinding state capture domain cluster)
      1 -> do
        state <- decode
        capture <- decode
        domain <- decode
        cluster <- decode
        unless
          (state == Nothing || capture == Nothing || domain == Nothing)
          (fail "noncanonical optional retained names")
        either (fail . show) pure (mkOptionalRetainedNameBinding state capture domain cluster)
      _ -> fail "retained audit names version"
