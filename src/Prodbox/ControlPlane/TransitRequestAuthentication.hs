{-# LANGUAGE OverloadedStrings #-}

-- | Production request-signing capability backed by non-exportable Vault
-- Transit Ed25519 keys.  Public generations are resolved once through the
-- caller's Kubernetes-auth session; signing refuses a rotated generation until
-- the process restarts and pins the new public half deliberately.
module Prodbox.ControlPlane.TransitRequestAuthentication
  ( TransitPublicGenerationError (..)
  , resolveTransitPublicGeneration
  , resolveTransitPublicGenerationDetailed
  , resolveTransitRequestSigningCapability
  , transitAuthenticatedClientProviders
  )
where

import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders (..)
  )
import Prodbox.ControlPlane.AuthenticationRegistry
  ( ControlPlaneSigningKeyRef
  , controlPlaneSigningKeyName
  , controlPlaneSigningKeyPrincipal
  )
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal)
import Prodbox.ControlPlane.Coordinate (AuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestSigningCapability
  , mkRequestNonce
  , mkRequestSigningCapability
  , mkSigningKeyGeneration
  , signingKeyGenerationValue
  )
import Prodbox.Http.Client (renderHttpError)
import Prodbox.Lifecycle.Authority.Genesis (AuthorityEpoch)
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , addAuthorityDuration
  , authorityTimeFromMicros
  )
import Prodbox.Vault.Client
  ( TransitSignature (..)
  , TransitSigningKeyInfo (..)
  , vaultReadTransitSigningKey
  , vaultTransitSignEd25519
  )
import Prodbox.Vault.Session
  ( VaultSession
  , VaultSessionOperationError (..)
  , renderVaultSessionError
  , sessionAddress
  , withSessionToken
  , withSessionTokenDetailed
  )

-- | Secret-safe provenance for one Transit public-generation lookup.  The
-- session layer retains acquisition/relogin/request boundaries; identity
-- mismatch is separate from every Vault or transport failure.
data TransitPublicGenerationError
  = TransitPublicGenerationVaultFailure !VaultSessionOperationError
  | TransitPublicGenerationIdentityMismatch
  deriving (Eq, Show)

resolveTransitPublicGeneration
  :: VaultSession
  -> ControlPlaneSigningKeyRef
  -> IO (Either Text (Natural, ByteString))
resolveTransitPublicGeneration session ref = do
  result <- resolveTransitPublicGenerationDetailed session ref
  pure (mapLeft renderFailure result)
 where
  renderFailure failure = case failure of
    TransitPublicGenerationVaultFailure operationError ->
      Text.pack (renderOperationError operationError)
    TransitPublicGenerationIdentityMismatch ->
      "Vault returned a different Transit signing-key identity"

resolveTransitPublicGenerationDetailed
  :: VaultSession
  -> ControlPlaneSigningKeyRef
  -> IO (Either TransitPublicGenerationError (Natural, ByteString))
resolveTransitPublicGenerationDetailed session ref = do
  result <-
    withSessionTokenDetailed session $ \token ->
      vaultReadTransitSigningKey
        (sessionAddress session)
        token
        (controlPlaneSigningKeyName ref)
  pure $ case result of
    Left err -> Left (TransitPublicGenerationVaultFailure err)
    Right info
      | transitSigningKeyName info /= controlPlaneSigningKeyName ref ->
          Left TransitPublicGenerationIdentityMismatch
      | otherwise ->
          Right
            ( transitSigningKeyVersion info
            , transitSigningPublicKey info
            )

renderOperationError :: VaultSessionOperationError -> String
renderOperationError operationError = case operationError of
  VaultSessionAcquisitionFailed sessionError -> renderVaultSessionError sessionError
  VaultSessionReloginFailed sessionError -> renderVaultSessionError sessionError
  VaultSessionRequestFailed httpError -> renderHttpError httpError

resolveTransitRequestSigningCapability
  :: VaultSession
  -> CallerPrincipal
  -> ControlPlaneSigningKeyRef
  -> IO (Either Text (RequestSigningCapability IO))
resolveTransitRequestSigningCapability session principal ref
  | controlPlaneSigningKeyPrincipal ref /= principal =
      pure (Left "Transit signing-key reference does not belong to the caller principal")
  | otherwise = do
      pinnedResult <- resolveTransitPublicGeneration session ref
      pure $ do
        (rawGeneration, publicBytes) <- pinnedResult
        generation <- mapLeft (Text.pack . show) (mkSigningKeyGeneration rawGeneration)
        mapLeft
          (Text.pack . show)
          ( mkRequestSigningCapability
              principal
              generation
              publicBytes
              (signPinned generation)
          )
 where
  signPinned generation bytes = do
    result <-
      withSessionToken session $ \token ->
        vaultTransitSignEd25519
          (sessionAddress session)
          token
          (controlPlaneSigningKeyName ref)
          bytes
    pure $ case result of
      Left err -> Left (Text.pack (renderHttpError err))
      Right signature
        | transitSignatureKeyVersion signature
            /= signingKeyGenerationValue generation ->
            Left "Vault Transit signing generation changed after startup pinning"
        | otherwise -> Right (transitSignatureBytes signature)

-- | Complete client providers for a service, operator, or harness caller.  The
-- caller supplies only its pinned Transit capability plus authoritative
-- scope/epoch observations; deadline and nonce use local bounded primitives.
-- No ambient AWS/Vault credential or raw private key enters this value.
transitAuthenticatedClientProviders
  :: RequestSigningCapability IO
  -> IO (Either Text AuthorityScope)
  -> IO (Either Text AuthorityEpoch)
  -> AuthorityDuration
  -> AuthenticatedClientProviders IO
transitAuthenticatedClientProviders signer provideScope provideEpoch lifetime =
  AuthenticatedClientProviders
    { provideAuthenticatedClientSigner = pure (Right signer)
    , provideAuthenticatedClientScope = provideScope
    , provideAuthenticatedClientEpoch = provideEpoch
    , provideAuthenticatedClientDeadline = do
        now <- currentAuthorityTime
        pure (Right (addAuthorityDuration now lifetime))
    , provideAuthenticatedClientNonce = do
        bytes <- getRandomBytes 32
        pure (mapLeft (Text.pack . show) (mkRequestNonce bytes))
    }

currentAuthorityTime :: IO AuthorityTime
currentAuthorityTime = do
  now <- getCurrentTime
  pure
    ( authorityTimeFromMicros
        ( fromInteger
            (max 0 (floor (utcTimeToPOSIXSeconds now * 1000000) :: Integer))
        )
    )

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft convert value = case value of
  Left err -> Left (convert err)
  Right result -> Right result
