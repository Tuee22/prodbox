{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Lifecycle.CredentialProvisioner.ImageIdentity
  ( CredentialProvisionerImagePullReference
  , mkCredentialProvisionerImagePullReference
  , renderCredentialProvisionerImagePullReference
  , credentialProvisionerRuntimeManifestDigest
  )
where

import Data.Char (isDigit, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text

newtype CredentialProvisionerImagePullReference
  = CredentialProvisionerImagePullReference Text
  deriving (Eq, Show)

mkCredentialProvisionerImagePullReference
  :: Text -> Text -> Either Text CredentialProvisionerImagePullReference
mkCredentialProvisionerImagePullReference rawRepository manifestDigest
  | Text.null repository = Left "image repository is empty"
  | Text.any isSpace repository = Left "image repository contains whitespace"
  | Text.isInfixOf "@" repository = Left "image repository already contains a digest"
  | credentialProvisionerRuntimeManifestDigest manifestDigest /= Just manifestDigest =
      Left "image manifest digest is invalid"
  | Text.length reference > 512 = Left "immutable image reference is too long"
  | otherwise = Right (CredentialProvisionerImagePullReference reference)
 where
  repository = Text.strip rawRepository
  reference = Text.concat [repository, "@", manifestDigest]

renderCredentialProvisionerImagePullReference
  :: CredentialProvisionerImagePullReference -> Text
renderCredentialProvisionerImagePullReference
  (CredentialProvisionerImagePullReference reference) = reference

credentialProvisionerRuntimeManifestDigest :: Text -> Maybe Text
credentialProvisionerRuntimeManifestDigest raw = do
  withoutScheme <- stripOptionalScheme raw
  digest <- stripOptionalRepository withoutScheme
  if isCanonicalDigest digest then Just digest else Nothing
 where
  stripOptionalScheme value =
    case Text.breakOn "://" value of
      (prefix, suffix)
        | Text.null suffix -> Just value
        | Text.null prefix
            || Text.count "://" value /= 1
            || Text.null (Text.drop 3 suffix) ->
            Nothing
        | otherwise -> Just (Text.drop 3 suffix)

  stripOptionalRepository value =
    case Text.breakOnEnd "@" value of
      (prefix, suffix)
        | Text.null prefix -> Just value
        | prefix == "@"
            || Text.count "@" value /= 1
            || Text.null suffix ->
            Nothing
        | otherwise -> Just suffix

  isCanonicalDigest value =
    Text.length value == 71
      && Text.isPrefixOf "sha256:" value
      && Text.all isLowerHex (Text.drop 7 value)

  isLowerHex character = isDigit character || character `elem` ['a' .. 'f']
