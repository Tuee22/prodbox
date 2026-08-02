{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exact, generation-checked Target Secret Agent decommission arm.
--
-- A tombstone binding fixes one registered target coordinate and expected
-- generation before effects are acquired.  The runner may select it only by
-- the reference already present in the authenticated manifest.  Deletion uses
-- KV-v2 metadata destruction (all versions), and every attempted response is
-- decided by an authoritative read-back, so a lost delete response converges.
module Prodbox.Lifecycle.Decommission.TargetTombstone
  ( TargetGenerationTombstoneBoundary
  , mkTargetGenerationTombstoneBoundary
  , vaultTargetGenerationTombstoneBoundary
  , TargetGenerationTombstoneBinding
  , TargetGenerationTombstoneBindingError (..)
  , mkTargetGenerationTombstoneBinding
  , TargetGenerationTombstoneRegistry
  , TargetGenerationTombstoneRegistryError (..)
  , mkTargetGenerationTombstoneRegistry
  , TargetGenerationTombstoneAction (..)
  , TargetGenerationTombstoneCommand (..)
  , TargetGenerationTombstoneRequest (..)
  , TargetGenerationTombstoneError (..)
  , TargetGenerationTombstoneResult (..)
  , TargetGenerationTombstoneResponse (..)
  , runTargetGenerationTombstone
  , runAuthorizedTargetGenerationTombstone
  , serveTargetGenerationTombstoneRequest
  , targetGenerationTombstoneHttpStatus
  , targetGenerationTombstoneSummary
  , targetGenerationTombstoneResponseBody
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.TargetMaterialRegistry (TargetSecretPayload)
import Prodbox.ControlPlane.TrustedTargetSink
  ( TrustedTargetSink
  , observeTrustedTargetSink
  , trustedTargetSinkCoordinate
  , vaultTrustedTargetSink
  )
import Prodbox.Http.Client (HttpError (HttpStatus), renderHttpError)
import Prodbox.Lifecycle.CheckpointAuthority
  ( TargetClusterSecretSink
  , targetSecretSinkIdentity
  , targetSecretSinkKvPath
  , targetSecretSinkVaultMount
  )
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest)
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionNode (TargetGeneration)
  , DecommissionTargetGeneration
  , SignedDecommissionManifest
  , VerifiedDecommissionManifest
  , decommissionTargetGenerationValue
  , manifestNodes
  , verifiedManifestPlan
  , verifySignedDecommissionManifest
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetSinkObservation (..)
  , TargetSinkRecord (..)
  , credentialGenerationValue
  )
import Prodbox.Vault.Client
  ( vaultKvDeleteMetadataV2
  , vaultKvMetadataExistsV2
  )
import Prodbox.Vault.Session
  ( VaultSession
  , sessionAddress
  , withSessionToken
  )

data TargetGenerationTombstoneBoundary m payload = TargetGenerationTombstoneBoundary
  { tombstoneBoundarySink :: !(TargetClusterSecretSink)
  , tombstoneBoundaryObserve :: m (TargetSinkObservation payload)
  , tombstoneBoundaryMetadataPresent :: !(Maybe (m (Either Text Bool)))
  , tombstoneBoundaryDestroyAllVersions :: m (Either Text ())
  }

mkTargetGenerationTombstoneBoundary
  :: TrustedTargetSink m payload
  -> m (Either Text ())
  -> TargetGenerationTombstoneBoundary m payload
mkTargetGenerationTombstoneBoundary trusted destroyAll =
  TargetGenerationTombstoneBoundary
    { tombstoneBoundarySink = trustedTargetSinkCoordinate trusted
    , tombstoneBoundaryObserve = observeTrustedTargetSink trusted
    , tombstoneBoundaryMetadataPresent = Nothing
    , tombstoneBoundaryDestroyAllVersions = destroyAll
    }

-- | Production Target-Agent binding.  The session is the Agent's cached
-- Kubernetes-auth session; no host root token or caller-selected path exists.
vaultTargetGenerationTombstoneBoundary
  :: VaultSession
  -> Text
  -> TargetClusterSecretSink
  -> Either Text (TargetGenerationTombstoneBoundary IO TargetSecretPayload)
vaultTargetGenerationTombstoneBoundary session localIdentity sink = do
  trusted <- vaultTrustedTargetSink session localIdentity sink
  Right
    ( (mkTargetGenerationTombstoneBoundary trusted destroyAll)
        { tombstoneBoundaryMetadataPresent = Just metadataPresent
        }
    )
 where
  destroyAll = do
    result <-
      withSessionToken session $ \token ->
        vaultKvDeleteMetadataV2
          (sessionAddress session)
          token
          (targetSecretSinkVaultMount sink)
          (targetSecretSinkKvPath sink)
    pure (first (Text.pack . renderHttpError) result)
  metadataPresent = do
    result <-
      withSessionToken session $ \token ->
        vaultKvMetadataExistsV2
          (sessionAddress session)
          token
          (targetSecretSinkVaultMount sink)
          (targetSecretSinkKvPath sink)
    pure $ case result of
      Right () -> Right True
      Left (HttpStatus 404 _) -> Right False
      Left err -> Left (Text.pack (renderHttpError err))

data TargetGenerationTombstoneBinding m payload = TargetGenerationTombstoneBinding
  { tombstoneBindingReference :: !Text
  , tombstoneBindingBoundary :: !(TargetGenerationTombstoneBoundary m payload)
  }

data TargetGenerationTombstoneBindingError
  = TargetTombstoneReferenceEmpty
  | TargetTombstoneReferenceIdentityMismatch !Text !Text
  deriving stock (Eq, Show)

-- | The manifest reference is exactly the Agent identity.  A caller cannot map
-- a signed @TargetGeneration "aws"@ node onto the home Agent boundary.
mkTargetGenerationTombstoneBinding
  :: Text
  -> TargetGenerationTombstoneBoundary m payload
  -> Either TargetGenerationTombstoneBindingError (TargetGenerationTombstoneBinding m payload)
mkTargetGenerationTombstoneBinding rawReference boundary
  | Text.null reference = Left TargetTombstoneReferenceEmpty
  | reference /= targetIdentity =
      Left (TargetTombstoneReferenceIdentityMismatch reference targetIdentity)
  | otherwise =
      Right
        TargetGenerationTombstoneBinding
          { tombstoneBindingReference = reference
          , tombstoneBindingBoundary = boundary
          }
 where
  reference = Text.strip rawReference
  targetIdentity = targetSecretSinkIdentity (tombstoneBoundarySink boundary)

newtype TargetGenerationTombstoneRegistry m payload
  = TargetGenerationTombstoneRegistry
      [TargetGenerationTombstoneBinding m payload]

data TargetGenerationTombstoneRegistryError
  = TargetTombstoneRegistryEmpty
  | TargetTombstoneRegistryDuplicateReference !Text
  deriving stock (Eq, Show)

mkTargetGenerationTombstoneRegistry
  :: [TargetGenerationTombstoneBinding m payload]
  -> Either TargetGenerationTombstoneRegistryError (TargetGenerationTombstoneRegistry m payload)
mkTargetGenerationTombstoneRegistry bindings
  | null bindings = Left TargetTombstoneRegistryEmpty
  | Just duplicateReference <- firstDuplicate references =
      Left (TargetTombstoneRegistryDuplicateReference duplicateReference)
  | otherwise = Right (TargetGenerationTombstoneRegistry bindings)
 where
  references = map tombstoneBindingReference bindings

  firstDuplicate remaining = case remaining of
    [] -> Nothing
    reference : rest
      | reference `elem` rest -> Just reference
      | otherwise -> firstDuplicate rest

data TargetGenerationTombstoneAction
  = ObserveTargetGenerationAbsence
  | DestroyTargetGeneration
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TargetGenerationTombstoneCommand = TargetGenerationTombstoneCommand
  { targetTombstoneReference :: !Text
  , targetTombstoneGeneration :: !DecommissionTargetGeneration
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TargetGenerationTombstoneRequest = TargetGenerationTombstoneRequest
  { targetTombstoneManifest :: !SignedDecommissionManifest
  , targetTombstoneCommand :: !TargetGenerationTombstoneCommand
  , targetTombstoneAction :: !TargetGenerationTombstoneAction
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TargetGenerationTombstoneError
  = TargetTombstoneBadRequest !ControlPlaneRequestCodecError
  | TargetTombstoneManifestInvalid !Text
  | TargetTombstoneNodeNotAuthorized !Text
  | TargetTombstoneReferenceNotRegistered !Text
  | TargetTombstoneObservationUnavailable !Text
  | TargetTombstoneGenerationMismatch !DecommissionTargetGeneration !CredentialGeneration
  | TargetTombstoneDeleteNotConfirmed !Text
  deriving stock (Eq, Show)

data TargetGenerationTombstoneResult
  = TargetGenerationAlreadyAbsent
  | TargetGenerationPresent
  | TargetGenerationDestroyedAndReadBack
  | TargetGenerationTombstoneRefused !TargetGenerationTombstoneError
  deriving stock (Eq, Show)

runTargetGenerationTombstone
  :: (Monad m)
  => VerifiedDecommissionManifest
  -> TargetGenerationTombstoneRegistry m payload
  -> TargetGenerationTombstoneAction
  -> TargetGenerationTombstoneCommand
  -> m TargetGenerationTombstoneResult
runTargetGenerationTombstone verified registry action command
  | TargetGeneration reference expectedGeneration
      `notElem` manifestNodes (verifiedManifestPlan verified) =
      refuse (TargetTombstoneNodeNotAuthorized reference)
  | otherwise =
      runAuthorizedTargetGenerationTombstone registry action command
 where
  reference = Text.strip (targetTombstoneReference command)
  expectedGeneration = targetTombstoneGeneration command
  refuse = pure . TargetGenerationTombstoneRefused

-- | Execute the already-authorized exact member.  Callers must first verify a
-- nominal proof family (the decommission manifest above or an Admin Action
-- permit endpoint); this helper performs no proof-family conversion.
runAuthorizedTargetGenerationTombstone
  :: (Monad m)
  => TargetGenerationTombstoneRegistry m payload
  -> TargetGenerationTombstoneAction
  -> TargetGenerationTombstoneCommand
  -> m TargetGenerationTombstoneResult
runAuthorizedTargetGenerationTombstone registry action command =
  case lookupBinding reference registry of
    Nothing -> refuse (TargetTombstoneReferenceNotRegistered reference)
    Just binding -> runBinding binding
 where
  reference = Text.strip (targetTombstoneReference command)
  expectedGeneration = targetTombstoneGeneration command
  refuse = pure . TargetGenerationTombstoneRefused

  runBinding binding = do
    let boundary = tombstoneBindingBoundary binding
    before <- tombstoneBoundaryObserve boundary
    case before of
      TargetSinkMissing -> do
        metadata <- observeMetadata boundary before
        case metadata of
          Left detail -> refuse (TargetTombstoneObservationUnavailable detail)
          Right False -> pure TargetGenerationAlreadyAbsent
          Right True
            | action == ObserveTargetGenerationAbsence ->
                pure TargetGenerationPresent
            | otherwise -> destroyAndConfirm boundary
      TargetSinkRetired ->
        refuse (TargetTombstoneObservationUnavailable "logical retirement is not physical absence")
      TargetSinkUnobservable detail ->
        refuse (TargetTombstoneObservationUnavailable detail)
      TargetSinkUnbounded observed limit ->
        refuse
          ( TargetTombstoneObservationUnavailable
              ( "target observation exceeded bound: "
                  <> Text.pack (show observed)
                  <> "/"
                  <> Text.pack (show limit)
              )
          )
      TargetSinkChanging detail ->
        refuse (TargetTombstoneObservationUnavailable detail)
      TargetSinkObserved _ record
        | credentialGenerationValue (targetSinkRecordGeneration record)
            /= decommissionTargetGenerationValue expectedGeneration ->
            refuse
              ( TargetTombstoneGenerationMismatch
                  expectedGeneration
                  (targetSinkRecordGeneration record)
              )
        | action == ObserveTargetGenerationAbsence ->
            pure TargetGenerationPresent
        | otherwise -> destroyAndConfirm boundary

  destroyAndConfirm boundary = do
    attempted <- tombstoneBoundaryDestroyAllVersions boundary
    after <- tombstoneBoundaryObserve boundary
    metadata <- observeMetadata boundary after
    pure $ case metadata of
      Right False -> TargetGenerationDestroyedAndReadBack
      Right True ->
        TargetGenerationTombstoneRefused
          (TargetTombstoneDeleteNotConfirmed (attemptDetail attempted <> presentDetail after))
      Left detail ->
        TargetGenerationTombstoneRefused
          (TargetTombstoneDeleteNotConfirmed (attemptDetail attempted <> detail))

  observeMetadata boundary fallback =
    case tombstoneBoundaryMetadataPresent boundary of
      Just observe -> observe
      Nothing -> pure (metadataFromTargetObservation fallback)

  metadataFromTargetObservation observed = case observed of
    TargetSinkMissing -> Right False
    TargetSinkObserved _ _ -> Right True
    TargetSinkRetired -> Left "logical retirement is not physical absence"
    TargetSinkUnobservable detail -> Left detail
    TargetSinkChanging detail -> Left detail
    TargetSinkUnbounded observedBytes limit ->
      Left
        ( "target observation exceeded bound: "
            <> Text.pack (show observedBytes)
            <> "/"
            <> Text.pack (show limit)
        )

  presentDetail observed = case observed of
    TargetSinkObserved _ remaining ->
      "generation remains present: "
        <> Text.pack
          (show (credentialGenerationValue (targetSinkRecordGeneration remaining)))
    TargetSinkMissing -> "target metadata remains present"
    TargetSinkRetired -> "logical retirement is not physical absence"
    TargetSinkUnobservable detail -> detail
    TargetSinkChanging detail -> detail
    TargetSinkUnbounded observedBytes limit ->
      "target observation exceeded bound: "
        <> Text.pack (show observedBytes)
        <> "/"
        <> Text.pack (show limit)

  attemptDetail attempted = case attempted of
    Right () -> ""
    Left detail -> "delete response unavailable: " <> detail <> "; "

lookupBinding
  :: Text
  -> TargetGenerationTombstoneRegistry m payload
  -> Maybe (TargetGenerationTombstoneBinding m payload)
lookupBinding reference (TargetGenerationTombstoneRegistry bindings) =
  case filter ((== reference) . tombstoneBindingReference) bindings of
    [binding] -> Just binding
    _ -> Nothing

serveTargetGenerationTombstoneRequest
  :: (Monad m)
  => Int
  -> FrameDigest
  -> TargetGenerationTombstoneRegistry m payload
  -> LazyByteString.ByteString
  -> m TargetGenerationTombstoneResult
serveTargetGenerationTombstoneRequest maximumBytes expectedSigner registry body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (TargetGenerationTombstoneRefused (TargetTombstoneBadRequest err))
    Right request ->
      case verifySignedDecommissionManifest expectedSigner (targetTombstoneManifest request) of
        Left err ->
          pure
            ( TargetGenerationTombstoneRefused
                (TargetTombstoneManifestInvalid (Text.pack (show err)))
            )
        Right verified ->
          runTargetGenerationTombstone
            verified
            registry
            (targetTombstoneAction request)
            (targetTombstoneCommand request)

targetGenerationTombstoneHttpStatus :: TargetGenerationTombstoneResult -> Int
targetGenerationTombstoneHttpStatus result = case result of
  TargetGenerationAlreadyAbsent -> 200
  TargetGenerationPresent -> 200
  TargetGenerationDestroyedAndReadBack -> 200
  TargetGenerationTombstoneRefused err -> case err of
    TargetTombstoneBadRequest _ -> 400
    TargetTombstoneManifestInvalid _ -> 403
    TargetTombstoneNodeNotAuthorized _ -> 403
    TargetTombstoneReferenceNotRegistered _ -> 404
    TargetTombstoneObservationUnavailable _ -> 503
    TargetTombstoneGenerationMismatch _ _ -> 409
    TargetTombstoneDeleteNotConfirmed _ -> 503

targetGenerationTombstoneSummary :: TargetGenerationTombstoneResult -> Text
targetGenerationTombstoneSummary result = case result of
  TargetGenerationAlreadyAbsent -> "target-generation-already-absent"
  TargetGenerationPresent -> "target-generation-present"
  TargetGenerationDestroyedAndReadBack -> "target-generation-destroyed"
  TargetGenerationTombstoneRefused err -> case err of
    TargetTombstoneBadRequest codec ->
      "target-generation-bad-request-" <> controlPlaneRequestCodecToken codec
    TargetTombstoneManifestInvalid _ -> "target-generation-manifest-invalid"
    TargetTombstoneNodeNotAuthorized _ -> "target-generation-not-authorized"
    TargetTombstoneReferenceNotRegistered _ -> "target-generation-not-registered"
    TargetTombstoneObservationUnavailable _ -> "target-generation-unobservable"
    TargetTombstoneGenerationMismatch _ _ -> "target-generation-mismatch"
    TargetTombstoneDeleteNotConfirmed _ -> "target-generation-delete-unconfirmed"

data TargetGenerationTombstoneResponse
  = TargetTombstoneResponseAlreadyAbsent
  | TargetTombstoneResponsePresent
  | TargetTombstoneResponseDestroyed
  | TargetTombstoneResponseRefused !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

targetGenerationTombstoneResponseBody
  :: TargetGenerationTombstoneResult
  -> ByteString
targetGenerationTombstoneResponseBody result =
  LazyByteString.toStrict
    ( encodeControlPlaneResponse $ case result of
        TargetGenerationAlreadyAbsent -> TargetTombstoneResponseAlreadyAbsent
        TargetGenerationPresent -> TargetTombstoneResponsePresent
        TargetGenerationDestroyedAndReadBack -> TargetTombstoneResponseDestroyed
        TargetGenerationTombstoneRefused _ ->
          TargetTombstoneResponseRefused (targetGenerationTombstoneSummary result)
    )
