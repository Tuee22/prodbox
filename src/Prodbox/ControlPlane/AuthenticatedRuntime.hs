{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Typed installation boundary between mounted non-secret authentication
-- topology, pinned public Transit generations, retained replay state, and a
-- role's authenticated handler.
module Prodbox.ControlPlane.AuthenticatedRuntime
  ( ControlPlaneAuthenticationWire (..)
  , ControlPlaneTrustedCallerWire (..)
  , ControlPlaneAuthenticationConfigError (..)
  , ValidatedAuthenticationTopology
  , validateControlPlaneAuthenticationWire
  , validatedAuthenticationSigningPrincipal
  , validatedAuthenticationSigningKeyRef
  , resolveRouteTrustRegistryWith
  , AuthenticatedRuntimeInputs (..)
  , AuthenticatedRuntimeInstallError (..)
  , installAuthenticatedRuntimeInterpreter
  , AuthenticatedRuntimeProvisioningGap (..)
  , authenticatedRuntimeUnavailableInterpreter
  )
where

import Control.Monad (foldM)
import Data.ByteString (ByteString)
import Data.List (find, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall qualified
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler
  , AuthenticatedRoleProviders
  , authenticatedRoleInterpreter
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedTransportBounds
  , RouteTrustRegistry
  , RouteTrustRegistryError (..)
  , mkRouteTrustRegistry
  )
import Prodbox.ControlPlane.AuthenticationRegistry
  ( ControlPlaneSigningKeyRef
  , controlPlaneRouteCallerTopology
  , controlPlaneSigningKeyName
  , controlPlaneSigningKeyPrincipal
  , controlPlaneSigningKeyRefFromName
  , localServiceCaller
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal
  , callerPrincipalFromCode
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestKeyError
  , SigningKeyGenerationError
  , TrustedRequestKey
  , mkSigningKeyGeneration
  , mkTrustedRequestKey
  )
import Prodbox.ControlPlane.RequestReplay
  ( ReplayCasAttempts
  , RequestReplayLimits
  , RequestReplayRepository
  )
import Prodbox.ControlPlane.RoleReadiness
  ( constantRoleReadinessSource
  , unobservedRoleReadinessFacts
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute
  , allControlPlaneRoutes
  , controlPlaneRoutePath
  , controlPlaneRouteRole
  )
import Prodbox.ControlPlane.Server
  ( RoleInterpreter (RoleInterpreter, interpreterHandle, interpreterReadiness)
  )
import Prodbox.Lifecycle.Lease (AuthorityDuration)
import Prodbox.Runtime.Role (RuntimeRole)

-- | One non-secret reference from a local route to the canonical Transit key
-- of an allowed caller.  Public bytes and generations are deliberately absent:
-- the running role resolves and pins them through its own Vault session.
data ControlPlaneTrustedCallerWire = ControlPlaneTrustedCallerWire
  { trusted_route_path :: !Text
  , trusted_caller_code :: !Natural
  , trusted_signing_key_name :: !Text
  }
  deriving (Generic, Show)

instance Dhall.FromDhall ControlPlaneTrustedCallerWire

-- | Mounted role-local authentication topology.  The signing key is a public
-- reference only; possession of this document grants no signing authority.
data ControlPlaneAuthenticationWire = ControlPlaneAuthenticationWire
  { maximum_trusted_callers_per_route :: !Natural
  , signing_principal_code :: !Natural
  , signing_key_name :: !Text
  , trusted_callers :: ![ControlPlaneTrustedCallerWire]
  }
  deriving (Generic, Show)

instance Dhall.FromDhall ControlPlaneAuthenticationWire

data ControlPlaneAuthenticationConfigError
  = ControlPlaneAuthenticationRoutePathUnknown !Text
  | ControlPlaneAuthenticationRouteNotOwned !RuntimeRole !ControlPlaneRoute
  | ControlPlaneAuthenticationCallerCodeOutOfRange !Natural
  | ControlPlaneAuthenticationCallerCodeUnknown !Word
  | ControlPlaneAuthenticationSigningPrincipalMismatch !CallerPrincipal !CallerPrincipal
  | ControlPlaneAuthenticationSigningKeyUnknown !Text
  | ControlPlaneAuthenticationSigningKeyPrincipalMismatch
      !CallerPrincipal
      !CallerPrincipal
  | ControlPlaneAuthenticationRouteCallerTopologyMismatch
  | ControlPlaneAuthenticationPublicGenerationUnavailable !Text !Text
  | ControlPlaneAuthenticationSigningGenerationInvalid !SigningKeyGenerationError
  | ControlPlaneAuthenticationRequestKeyInvalid !RequestKeyError
  | ControlPlaneAuthenticationRouteTrustInvalid !RouteTrustRegistryError
  deriving (Eq, Show)

data ValidatedTrustedCaller = ValidatedTrustedCaller
  { validatedTrustedRoute :: !ControlPlaneRoute
  , validatedTrustedCaller :: !CallerPrincipal
  , validatedTrustedKeyRef :: !ControlPlaneSigningKeyRef
  }

data ValidatedAuthenticationTopology = ValidatedAuthenticationTopology
  { validatedAuthenticationRole :: !RuntimeRole
  , validatedAuthenticationMaximum :: !Natural
  , validatedAuthenticationSigningPrincipal :: !CallerPrincipal
  , validatedAuthenticationSigningKeyRef :: !ControlPlaneSigningKeyRef
  , validatedAuthenticationCallers :: ![ValidatedTrustedCaller]
  }

validateControlPlaneAuthenticationWire
  :: RuntimeRole
  -> ControlPlaneAuthenticationWire
  -> Either ControlPlaneAuthenticationConfigError ValidatedAuthenticationTopology
validateControlPlaneAuthenticationWire role wire = do
  signingCaller <- callerFromNatural (signing_principal_code wire)
  let expectedSigningCaller = localServiceCaller role
  if signingCaller == expectedSigningCaller
    then pure ()
    else
      Left
        ( ControlPlaneAuthenticationSigningPrincipalMismatch
            expectedSigningCaller
            signingCaller
        )
  signerRef <- keyRefForCaller signingCaller (signing_key_name wire)
  entries <- traverse (validateTrustedEntry role) (trusted_callers wire)
  let actualTopology =
        sort
          [ (validatedTrustedRoute entry, validatedTrustedCaller entry)
          | entry <- entries
          ]
      expectedTopology =
        sort
          [ (route, caller)
          | (route, callers) <- controlPlaneRouteCallerTopology
          , controlPlaneRouteRole route == role
          , caller <- callers
          ]
  if actualTopology == expectedTopology
    then pure ()
    else Left ControlPlaneAuthenticationRouteCallerTopologyMismatch
  -- Registry construction owns the hard maximum and per-route capacity checks.
  -- Use deterministic placeholder public keys only for no purpose here; those
  -- checks are repeated after real generations resolve below.
  if maximum_trusted_callers_per_route wire == 0
    then
      Left
        ( ControlPlaneAuthenticationRouteTrustInvalid
            RouteTrustMaximumMustBePositive
        )
    else pure ()
  pure
    ValidatedAuthenticationTopology
      { validatedAuthenticationRole = role
      , validatedAuthenticationMaximum = maximum_trusted_callers_per_route wire
      , validatedAuthenticationSigningPrincipal = signingCaller
      , validatedAuthenticationSigningKeyRef = signerRef
      , validatedAuthenticationCallers = entries
      }

validateTrustedEntry
  :: RuntimeRole
  -> ControlPlaneTrustedCallerWire
  -> Either ControlPlaneAuthenticationConfigError ValidatedTrustedCaller
validateTrustedEntry role wire = do
  route <-
    maybe
      (Left (ControlPlaneAuthenticationRoutePathUnknown (trusted_route_path wire)))
      Right
      ( find
          ((== trusted_route_path wire) . Text.pack . controlPlaneRoutePath)
          allControlPlaneRoutes
      )
  if controlPlaneRouteRole route == role
    then pure ()
    else Left (ControlPlaneAuthenticationRouteNotOwned role route)
  caller <- callerFromNatural (trusted_caller_code wire)
  keyRef <- keyRefForCaller caller (trusted_signing_key_name wire)
  pure
    ValidatedTrustedCaller
      { validatedTrustedRoute = route
      , validatedTrustedCaller = caller
      , validatedTrustedKeyRef = keyRef
      }

callerFromNatural
  :: Natural -> Either ControlPlaneAuthenticationConfigError CallerPrincipal
callerFromNatural value = do
  callerCode <- naturalToWord value
  maybe
    (Left (ControlPlaneAuthenticationCallerCodeUnknown callerCode))
    Right
    (callerPrincipalFromCode callerCode)

keyRefForCaller
  :: CallerPrincipal
  -> Text
  -> Either ControlPlaneAuthenticationConfigError ControlPlaneSigningKeyRef
keyRefForCaller caller name = do
  ref <-
    maybe
      (Left (ControlPlaneAuthenticationSigningKeyUnknown name))
      Right
      (controlPlaneSigningKeyRefFromName name)
  if controlPlaneSigningKeyPrincipal ref == caller
    then Right ref
    else
      Left
        ( ControlPlaneAuthenticationSigningKeyPrincipalMismatch
            caller
            (controlPlaneSigningKeyPrincipal ref)
        )

naturalToWord
  :: Natural -> Either ControlPlaneAuthenticationConfigError Word
naturalToWord value
  | toInteger value > toInteger (maxBound :: Word) =
      Left (ControlPlaneAuthenticationCallerCodeOutOfRange value)
  | otherwise = Right (fromIntegral value)

-- | Resolve each unique non-secret key reference exactly once, then construct
-- the role-total registry from the pinned generations.  The injected lookup is
-- the pure-test seam; production supplies a Vault-session Transit lookup.
resolveRouteTrustRegistryWith
  :: (Monad m)
  => (ControlPlaneSigningKeyRef -> m (Either Text (Natural, ByteString)))
  -> ValidatedAuthenticationTopology
  -> m (Either ControlPlaneAuthenticationConfigError RouteTrustRegistry)
resolveRouteTrustRegistryWith resolveKey topology = do
  resolved <- foldM resolveOne (Right Map.empty) (validatedAuthenticationCallers topology)
  pure $ do
    keyMap <- resolved
    entries <- traverse (trustedEntryFromPinned keyMap) (validatedAuthenticationCallers topology)
    mapLeft
      ControlPlaneAuthenticationRouteTrustInvalid
      ( mkRouteTrustRegistry
          (validatedAuthenticationRole topology)
          (validatedAuthenticationMaximum topology)
          entries
      )
 where
  resolveOne accumulated entry = case accumulated of
    Left err -> pure (Left err)
    Right keys ->
      let ref = validatedTrustedKeyRef entry
          name = controlPlaneSigningKeyName ref
       in case Map.lookup name keys of
            Just _ -> pure (Right keys)
            Nothing -> do
              result <- resolveKey ref
              pure $ case result of
                Left detail ->
                  Left
                    ( ControlPlaneAuthenticationPublicGenerationUnavailable
                        name
                        detail
                    )
                Right pinned -> Right (Map.insert name pinned keys)

trustedEntryFromPinned
  :: Map Text (Natural, ByteString)
  -> ValidatedTrustedCaller
  -> Either
       ControlPlaneAuthenticationConfigError
       (ControlPlaneRoute, TrustedRequestKey)
trustedEntryFromPinned keyMap entry = do
  let ref = validatedTrustedKeyRef entry
      name = controlPlaneSigningKeyName ref
  (rawGeneration, publicBytes) <-
    maybe
      ( Left
          ( ControlPlaneAuthenticationPublicGenerationUnavailable
              name
              "resolved generation disappeared"
          )
      )
      Right
      (Map.lookup name keyMap)
  generation <-
    mapLeft
      ControlPlaneAuthenticationSigningGenerationInvalid
      (mkSigningKeyGeneration rawGeneration)
  trusted <-
    mapLeft
      ControlPlaneAuthenticationRequestKeyInvalid
      (mkTrustedRequestKey (validatedTrustedCaller entry) generation publicBytes)
  pure (validatedTrustedRoute entry, trusted)

-- | Existential retained-revision input.  Code installing an authenticated
-- handler cannot observe or substitute the concrete repository revision type.
data AuthenticatedRuntimeInputs m where
  AuthenticatedRuntimeInputs
    :: RuntimeRole
    -> AuthenticatedTransportBounds
    -> AuthorityDuration
    -> AuthenticatedRoleProviders m
    -> ReplayCasAttempts
    -> RequestReplayLimits
    -> RequestReplayRepository m revision
    -> AuthenticatedRuntimeInputs m

data AuthenticatedRuntimeInstallError
  = AuthenticatedRuntimeRoleMismatch !RuntimeRole !RuntimeRole
  deriving (Eq, Show)

installAuthenticatedRuntimeInterpreter
  :: (Monad m)
  => RuntimeRole
  -> AuthenticatedRuntimeInputs m
  -> AuthenticatedRoleHandler m
  -> Either AuthenticatedRuntimeInstallError (RoleInterpreter m)
installAuthenticatedRuntimeInterpreter expectedRole inputs handler =
  case inputs of
    AuthenticatedRuntimeInputs
      suppliedRole
      transportBounds
      maximumLifetime
      providers
      casAttempts
      replayLimits
      replayRepository
        | suppliedRole /= expectedRole ->
            Left (AuthenticatedRuntimeRoleMismatch expectedRole suppliedRole)
        | otherwise ->
            Right
              ( authenticatedRoleInterpreter
                  transportBounds
                  maximumLifetime
                  providers
                  expectedRole
                  casAttempts
                  replayLimits
                  replayRepository
                  handler
              )

data AuthenticatedRuntimeProvisioningGap
  = AuthenticatedRuntimeTrustProvisioningMissing !RuntimeRole
  | AuthenticatedRuntimeTrustProvisioningInvalid
      !RuntimeRole
      !ControlPlaneAuthenticationConfigError
  | AuthenticatedRuntimeRetainedReplayAndEpochProvisioningMissing !RuntimeRole
  deriving (Eq, Show)

authenticatedRuntimeUnavailableInterpreter
  :: (Applicative m)
  => AuthenticatedRuntimeProvisioningGap
  -> RoleInterpreter m
authenticatedRuntimeUnavailableInterpreter gap =
  RoleInterpreter
    { interpreterReadiness =
        constantRoleReadinessSource
          (unobservedRoleReadinessFacts "authenticated-runtime")
    , interpreterHandle = \_ _ -> pure (Just (503, provisioningGapBody gap))
    }

provisioningGapBody :: AuthenticatedRuntimeProvisioningGap -> ByteString
provisioningGapBody gap = case gap of
  AuthenticatedRuntimeTrustProvisioningMissing _ ->
    "authenticated-runtime-trust-provisioning-missing\n"
  AuthenticatedRuntimeTrustProvisioningInvalid _ _ ->
    "authenticated-runtime-trust-provisioning-invalid\n"
  AuthenticatedRuntimeRetainedReplayAndEpochProvisioningMissing _ ->
    "authenticated-runtime-retained-replay-and-epoch-provisioning-missing\n"

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft convert value = case value of
  Left err -> Left (convert err)
  Right result -> Right result
