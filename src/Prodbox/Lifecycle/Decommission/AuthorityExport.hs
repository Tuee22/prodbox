{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authority-owned preparation of the signed total-decommission manifest.
--
-- The request supplies only the public, already-validated runner binding.  The
-- plan comes from the Authority repository, normal admission is frozen before
-- signing, and the private Ed25519 key remains inside the injected signer
-- (Vault Transit in production).  A key rotation between public-key read and
-- sign is refused rather than producing a manifest whose signer cannot be
-- pinned.
module Prodbox.Lifecycle.Decommission.AuthorityExport
  ( authorityDecommissionSigningKeyName
  , AuthorityManifestSigner (..)
  , vaultAuthorityManifestSigner
  , AuthorityDecommissionExportRepository (..)
  , AuthorityDecommissionExportRequest (..)
  , AuthorityDecommissionExportError (..)
  , AuthorityDecommissionExportResult (..)
  , runAuthorityDecommissionExport
  , serveAuthorityDecommissionExportRequest
  , authorityDecommissionExportHttpStatus
  , authorityDecommissionExportSummary
  , AuthorityDecommissionExportResponse (..)
  , authorityDecommissionExportResponseBody
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.Http.Client (HttpError (HttpDecode), renderHttpError)
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionLocalDataDisposition
  , DecommissionManifest
  , ManifestPublicKey
  , SignedDecommissionManifest
  , VerifiedDecommissionManifest
  , manifestSigningPayload
  , mkManifestPublicKey
  , verifiedSignedManifest
  , verifyExternallySignedDecommissionManifest
  )
import Prodbox.Lifecycle.Decommission.Verifier
  ( VerifierBinding
  , validateVerifierBinding
  )
import Prodbox.Vault.Client
  ( TransitSignature (..)
  , TransitSigningKeyInfo (..)
  , vaultReadTransitSigningKey
  , vaultTransitSignEd25519
  )
import Prodbox.Vault.Session
  ( VaultSession
  , sessionAddress
  , withSessionToken
  )

authorityDecommissionSigningKeyName :: Text
authorityDecommissionSigningKeyName = "prodbox-authority-genesis-signing"

-- | Non-exportable signing boundary.  Both callbacks return the concrete key
-- generation so a concurrent rotation cannot be hidden.
data AuthorityManifestSigner m = AuthorityManifestSigner
  { readAuthorityManifestPublicKey
      :: m (Either Text (Natural, ManifestPublicKey))
  , signAuthorityManifestPayload
      :: ByteString
      -> m (Either Text (Natural, ByteString))
  }

-- | Production signer over the Lifecycle Authority role's cached Vault
-- Kubernetes-auth session.  Only public bytes and a signature leave Transit.
vaultAuthorityManifestSigner :: VaultSession -> AuthorityManifestSigner IO
vaultAuthorityManifestSigner session =
  AuthorityManifestSigner
    { readAuthorityManifestPublicKey =
        fmap (first (Text.pack . renderHttpError)) $
          withSessionToken session $ \token -> do
            result <-
              vaultReadTransitSigningKey
                (sessionAddress session)
                token
                authorityDecommissionSigningKeyName
            pure $ do
              info <- result
              publicKey <-
                first
                  (const (HttpDecode "Transit signing public key is not a valid Ed25519 public key"))
                  (mkManifestPublicKey (transitSigningPublicKey info))
              Right (transitSigningKeyVersion info, publicKey)
    , signAuthorityManifestPayload = \payload ->
        fmap (first (Text.pack . renderHttpError)) $
          withSessionToken session $ \token -> do
            result <-
              vaultTransitSignEd25519
                (sessionAddress session)
                token
                authorityDecommissionSigningKeyName
                payload
            pure $ do
              signature <- result
              Right
                ( transitSignatureKeyVersion signature
                , transitSignatureBytes signature
                )
    }

-- | Authority-owned state/effect boundary.  The manifest plan is not caller
-- supplied; it is read from the Authority's deterministic registered inventory.
data AuthorityDecommissionExportRepository m = AuthorityDecommissionExportRepository
  { freezeAuthorityAdmission :: m (Either Text ())
  , readAuthorityDecommissionPlan
      :: DecommissionLocalDataDisposition
      -> m (Either Text DecommissionManifest)
  , commitAuthorityDecommissionManifest
      :: VerifiedDecommissionManifest
      -> m (Either Text ())
  }

-- | Sprint 4.85: the request carries the public runner binding and one closed
-- operator decision.
--
-- The plan itself is still not caller-supplied — the node set and its order
-- come from the Authority's registered inventory. What the inventory cannot
-- supply is the /disposition/ of the retained local data root: it knows the
-- root exists, not what should become of it, and both candidate answers are
-- decisions somebody must make on the record. So the decision arrives as a
-- two-valued choice, is placed into the plan by the Authority, and is signed
-- like every other node — which is what lets the runner refuse a manifest whose
-- disposition is not the one the operator typed.
data AuthorityDecommissionExportRequest = AuthorityDecommissionExportRequest
  { authorityExportVerifierBinding :: VerifierBinding
  , authorityExportLocalDataDisposition :: DecommissionLocalDataDisposition
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityDecommissionExportError
  = AuthorityExportBadRequest !ControlPlaneRequestCodecError
  | AuthorityExportVerifierBindingInvalid !Text
  | AuthorityExportFreezeFailed !Text
  | AuthorityExportPlanUnavailable !Text
  | AuthorityExportSignerUnavailable !Text
  | AuthorityExportSignerGenerationChanged !Natural !Natural
  | AuthorityExportSignatureInvalid !Text
  | AuthorityExportCommitFailed !Text
  deriving stock (Eq, Show)

data AuthorityDecommissionExportResult
  = AuthorityDecommissionExported !VerifiedDecommissionManifest
  | AuthorityDecommissionExportRefused !AuthorityDecommissionExportError
  deriving stock (Eq, Show)

runAuthorityDecommissionExport
  :: (Monad m)
  => AuthorityDecommissionExportRepository m
  -> AuthorityManifestSigner m
  -> AuthorityDecommissionExportRequest
  -> m AuthorityDecommissionExportResult
runAuthorityDecommissionExport repository signer request =
  case validateVerifierBinding (authorityExportVerifierBinding request) of
    Left err ->
      pure
        ( AuthorityDecommissionExportRefused
            (AuthorityExportVerifierBindingInvalid (Text.pack (show err)))
        )
    Right verifier -> do
      frozen <- freezeAuthorityAdmission repository
      case frozen of
        Left detail -> refuse (AuthorityExportFreezeFailed detail)
        Right () -> do
          planResult <-
            readAuthorityDecommissionPlan
              repository
              (authorityExportLocalDataDisposition request)
          case planResult of
            Left detail -> refuse (AuthorityExportPlanUnavailable detail)
            Right plan -> signAndCommit verifier plan
 where
  refuse = pure . AuthorityDecommissionExportRefused

  signAndCommit verifier plan = do
    publicResult <- readAuthorityManifestPublicKey signer
    case publicResult of
      Left detail -> refuse (AuthorityExportSignerUnavailable detail)
      Right (publicGeneration, publicKey) -> do
        signedResult <-
          signAuthorityManifestPayload
            signer
            (manifestSigningPayload plan verifier publicKey)
        case signedResult of
          Left detail -> refuse (AuthorityExportSignerUnavailable detail)
          Right (signatureGeneration, signatureBytes)
            | signatureGeneration /= publicGeneration ->
                refuse
                  ( AuthorityExportSignerGenerationChanged
                      publicGeneration
                      signatureGeneration
                  )
            | otherwise ->
                case verifyExternallySignedDecommissionManifest
                  plan
                  verifier
                  publicKey
                  signatureBytes of
                  Left err ->
                    refuse (AuthorityExportSignatureInvalid (Text.pack (show err)))
                  Right verified -> do
                    committed <- commitAuthorityDecommissionManifest repository verified
                    pure $ case committed of
                      Left detail ->
                        AuthorityDecommissionExportRefused
                          (AuthorityExportCommitFailed detail)
                      Right () -> AuthorityDecommissionExported verified

serveAuthorityDecommissionExportRequest
  :: (Monad m)
  => Int
  -> AuthorityDecommissionExportRepository m
  -> AuthorityManifestSigner m
  -> LazyByteString.ByteString
  -> m AuthorityDecommissionExportResult
serveAuthorityDecommissionExportRequest maximumBytes repository signer body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (AuthorityDecommissionExportRefused (AuthorityExportBadRequest err))
    Right request -> runAuthorityDecommissionExport repository signer request

authorityDecommissionExportHttpStatus :: AuthorityDecommissionExportResult -> ReplyStatus
authorityDecommissionExportHttpStatus result = case result of
  AuthorityDecommissionExported _ -> ReplyOk
  AuthorityDecommissionExportRefused err -> case err of
    AuthorityExportBadRequest _ -> ReplyBadRequest
    AuthorityExportVerifierBindingInvalid _ -> ReplyBadRequest
    AuthorityExportFreezeFailed _ -> ReplyServiceUnavailable
    AuthorityExportPlanUnavailable _ -> ReplyServiceUnavailable
    AuthorityExportSignerUnavailable _ -> ReplyServiceUnavailable
    AuthorityExportSignerGenerationChanged _ _ -> ReplyConflict
    AuthorityExportSignatureInvalid _ -> ReplyInternalError
    AuthorityExportCommitFailed _ -> ReplyServiceUnavailable

authorityDecommissionExportSummary :: AuthorityDecommissionExportResult -> Text
authorityDecommissionExportSummary result = case result of
  AuthorityDecommissionExported _ -> "decommission-exported"
  AuthorityDecommissionExportRefused err -> case err of
    AuthorityExportBadRequest codec ->
      "decommission-export-bad-request-" <> controlPlaneRequestCodecToken codec
    AuthorityExportVerifierBindingInvalid _ -> "decommission-export-verifier-invalid"
    AuthorityExportFreezeFailed _ -> "decommission-export-freeze-failed"
    AuthorityExportPlanUnavailable _ -> "decommission-export-plan-unavailable"
    AuthorityExportSignerUnavailable _ -> "decommission-export-signer-unavailable"
    AuthorityExportSignerGenerationChanged _ _ -> "decommission-export-signer-rotated"
    AuthorityExportSignatureInvalid _ -> "decommission-export-signature-invalid"
    AuthorityExportCommitFailed _ -> "decommission-export-commit-failed"

data AuthorityDecommissionExportResponse
  = AuthorityDecommissionExportResponseExported !SignedDecommissionManifest
  | AuthorityDecommissionExportResponseRefused !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

authorityDecommissionExportResponseBody
  :: AuthorityDecommissionExportResult
  -> ByteString
authorityDecommissionExportResponseBody result =
  LazyByteString.toStrict
    ( encodeControlPlaneResponse $ case result of
        AuthorityDecommissionExported verified ->
          AuthorityDecommissionExportResponseExported
            (verifiedSignedManifest verified)
        AuthorityDecommissionExportRefused _ ->
          AuthorityDecommissionExportResponseRefused
            (authorityDecommissionExportSummary result)
    )
