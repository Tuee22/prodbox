{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Retained logical caller generations. Structural registration does not
-- attest an origin; that observation belongs to the Authority interpreter.
module Prodbox.ControlPlane.RpcKeyRegistry
  ( RpcVaultIncarnation
  , mkRpcVaultIncarnation
  , rpcVaultIncarnationText
  , RpcKeyOrigin
  , mkRpcKeyOrigin
  , rpcKeyOriginScope
  , rpcKeyOriginVault
  , rpcKeyOriginRef
  , RpcObservedKey
  , mkRpcObservedKey
  , rpcObservedOrigin
  , rpcObservedNativeVersion
  , rpcObservedPublicKey
  , RpcKeyBindingStatus (..)
  , RpcKeyBinding
  , rpcKeyBindingObserved
  , rpcKeyBindingGeneration
  , rpcKeyBindingStatus
  , RpcKeyRegistry
  , rpcKeyRegistryScope
  , rpcKeyRegistryBindings
  , rpcKeyRegistryWatermark
  , RpcKeyRegistryError (..)
  , rpcKeyRegistryMaximumBytes
  , rpcKeyRegistryMaximumBindings
  , seedLegacyRpcKeyRegistry
  , registerRpcKey
  , retireRpcKey
  , lookupActiveRpcKey
  , selectActiveRpcKeyForOrigin
  , registeredRpcRouteTrust
  , encodeRpcKeyRegistry
  , decodeRpcKeyRegistry
  )
where

import Codec.Serialise (Serialise (decode, encode), deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.List (find, maximumBy)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (comparing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( RouteTrustRegistry
  , RouteTrustRegistryError
  , mkRouteTrustRegistry
  )
import Prodbox.ControlPlane.AuthenticationRegistry
  ( ControlPlaneSigningKeyRef
  , controlPlaneRouteCallerTopology
  , controlPlaneSigningKeyName
  , controlPlaneSigningKeyPrincipal
  , controlPlaneSigningKeyRefFromName
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal
  , allCallerPrincipals
  , callerPrincipalCode
  , callerPrincipalFromCode
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope, authorityScopeText, mkAuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication
  ( SigningKeyGeneration
  , mkSigningKeyGeneration
  , mkTrustedRequestKey
  , signingKeyGenerationValue
  )
import Prodbox.ControlPlane.Route (controlPlaneRouteRole)
import Prodbox.ControlPlane.RpcAdmissionBirthWire (rpcKeyRegistryMaximumBytes)
import Prodbox.Runtime.Role (RuntimeRole)

newtype RpcVaultIncarnation = RpcVaultIncarnation Text
  deriving stock (Eq, Ord, Show)

mkRpcVaultIncarnation :: Text -> Either RpcKeyRegistryError RpcVaultIncarnation
mkRpcVaultIncarnation value
  | value == "00000000-0000-0000-0000-000000000000" = Left RpcVaultIncarnationInvalid
  | Text.length value /= 36 = Left RpcVaultIncarnationInvalid
  | and (zipWith valid [0 :: Int ..] (Text.unpack value)) = Right (RpcVaultIncarnation value)
  | otherwise = Left RpcVaultIncarnationInvalid
 where
  valid index character
    | index `elem` [8, 13, 18, 23] = character == '-'
    | otherwise = character `elem` (['0' .. '9'] <> ['a' .. 'f'])

rpcVaultIncarnationText :: RpcVaultIncarnation -> Text
rpcVaultIncarnationText (RpcVaultIncarnation value) = value

data RpcKeyOrigin = RpcKeyOrigin
  { originScopeValue :: !AuthorityScope
  , originVaultValue :: !RpcVaultIncarnation
  , originRefValue :: !ControlPlaneSigningKeyRef
  }
  deriving stock (Eq, Ord, Show)

mkRpcKeyOrigin :: AuthorityScope -> RpcVaultIncarnation -> ControlPlaneSigningKeyRef -> RpcKeyOrigin
mkRpcKeyOrigin = RpcKeyOrigin

rpcKeyOriginScope :: RpcKeyOrigin -> AuthorityScope
rpcKeyOriginScope = originScopeValue

rpcKeyOriginVault :: RpcKeyOrigin -> RpcVaultIncarnation
rpcKeyOriginVault = originVaultValue

rpcKeyOriginRef :: RpcKeyOrigin -> ControlPlaneSigningKeyRef
rpcKeyOriginRef = originRefValue

data RpcObservedKey = RpcObservedKey
  { observedOriginValue :: !RpcKeyOrigin
  , observedNativeVersionValue :: !Natural
  , observedPublicKeyValue :: !ByteString
  }
  deriving stock (Eq, Show)

rpcObservedOrigin :: RpcObservedKey -> RpcKeyOrigin
rpcObservedOrigin = observedOriginValue

rpcObservedNativeVersion :: RpcObservedKey -> Natural
rpcObservedNativeVersion = observedNativeVersionValue

rpcObservedPublicKey :: RpcObservedKey -> ByteString
rpcObservedPublicKey = observedPublicKeyValue

mkRpcObservedKey
  :: RpcKeyOrigin -> Natural -> ByteString -> Either RpcKeyRegistryError RpcObservedKey
mkRpcObservedKey origin version public = do
  let ref = rpcKeyOriginRef origin
  unless
    (controlPlaneSigningKeyRefFromName (controlPlaneSigningKeyName ref) == Just ref)
    (Left RpcKeyReferenceInvalid)
  validateGeneration RpcNativeVersionInvalid version
  case Ed25519.publicKey public of
    CryptoFailed _ -> Left RpcPublicKeyInvalid
    CryptoPassed _ -> Right (RpcObservedKey origin version public)

data RpcKeyBindingStatus = RpcKeyActive | RpcKeyRetired
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RpcKeyBinding = RpcKeyBinding
  { bindingObservedValue :: !RpcObservedKey
  , bindingGenerationValue :: !SigningKeyGeneration
  , bindingStatusValue :: !RpcKeyBindingStatus
  }
  deriving stock (Eq, Show)

rpcKeyBindingObserved :: RpcKeyBinding -> RpcObservedKey
rpcKeyBindingObserved = bindingObservedValue

rpcKeyBindingGeneration :: RpcKeyBinding -> SigningKeyGeneration
rpcKeyBindingGeneration = bindingGenerationValue

rpcKeyBindingStatus :: RpcKeyBinding -> RpcKeyBindingStatus
rpcKeyBindingStatus = bindingStatusValue

data RpcKeyRegistry = RpcKeyRegistry
  { registryScopeValue :: !AuthorityScope
  , registryWatermarks :: !(Map CallerPrincipal Natural)
  , registryBindings :: !(Map (CallerPrincipal, SigningKeyGeneration) RpcKeyBinding)
  }
  deriving stock (Eq, Show)

-- The enclosing Authority aggregate stores the same bounded canonical bytes.
instance Serialise RpcKeyRegistry where
  encode = encode . LazyByteString.toStrict . serialise . registryWire
  decode = do
    bytes <- decode
    either (fail . show) pure (decodeRpcKeyRegistry bytes)

rpcKeyRegistryScope :: RpcKeyRegistry -> AuthorityScope
rpcKeyRegistryScope = registryScopeValue

rpcKeyRegistryBindings :: RpcKeyRegistry -> [RpcKeyBinding]
rpcKeyRegistryBindings = Map.elems . registryBindings

rpcKeyRegistryWatermark :: CallerPrincipal -> RpcKeyRegistry -> Maybe Natural
rpcKeyRegistryWatermark principal = Map.lookup principal . registryWatermarks

data RpcKeyRegistryError
  = RpcVaultIncarnationInvalid
  | RpcNativeVersionInvalid
  | RpcLogicalGenerationInvalid
  | RpcPublicKeyInvalid
  | RpcKeyReferenceInvalid
  | RpcLegacySeedIncomplete
  | RpcLegacySeedOriginInvalid
  | RpcKeyOriginAliased
  | RpcPublicKeyReused
  | RpcNativeVersionRegressed
  | RpcKeyAlreadyRetired
  | RpcKeyBindingMissing
  | RpcKeyRegistryCapacityReached
  | RpcKeyRegistryTooLarge
  | RpcKeyRegistryWireInvalid
  | RpcKeyRegistryNonCanonical
  | RpcKeyRegistryInvariantInvalid
  | RpcKeyRegistryObservationUnavailable
  | RpcCallerWithoutActiveKey !CallerPrincipal
  | RpcRouteTrustInvalid !RouteTrustRegistryError
  deriving stock (Eq, Show)

rpcKeyRegistryMaximumBindings :: Int
rpcKeyRegistryMaximumBindings = 256

maximumGeneration :: Natural
maximumGeneration = 2 ^ (64 :: Int) - 1

validateGeneration :: RpcKeyRegistryError -> Natural -> Either RpcKeyRegistryError ()
validateGeneration failure value = unless (value > 0 && value <= maximumGeneration) (Left failure)

keyPrincipal :: RpcObservedKey -> CallerPrincipal
keyPrincipal = controlPlaneSigningKeyPrincipal . rpcKeyOriginRef . rpcObservedOrigin

bindingPrincipal :: RpcKeyBinding -> CallerPrincipal
bindingPrincipal = keyPrincipal . rpcKeyBindingObserved

logicalGeneration :: Natural -> Either RpcKeyRegistryError SigningKeyGeneration
logicalGeneration value = do
  validateGeneration RpcLogicalGenerationInvalid value
  first (const RpcLogicalGenerationInvalid) (mkSigningKeyGeneration value)

-- | The one compatibility seed is complete and home-local. A partial seed
-- could silently allocate a slot already owned by a surviving old caller.
seedLegacyRpcKeyRegistry
  :: AuthorityScope -> [RpcObservedKey] -> Either RpcKeyRegistryError RpcKeyRegistry
seedLegacyRpcKeyRegistry scope observed = do
  unless
    ( length observed == length allCallerPrincipals
        && Set.fromList (map keyPrincipal observed) == Set.fromList allCallerPrincipals
    )
    (Left RpcLegacySeedIncomplete)
  unless
    ( all ((== scope) . rpcKeyOriginScope . rpcObservedOrigin) observed
        && Set.size (Set.fromList (map (rpcKeyOriginVault . rpcObservedOrigin) observed)) == 1
    )
    (Left RpcLegacySeedOriginInvalid)
  bindings <- traverse makeBinding observed
  let registry =
        RpcKeyRegistry
          scope
          (Map.fromList [(keyPrincipal key, rpcObservedNativeVersion key) | key <- observed])
          ( Map.fromList
              [((bindingPrincipal binding, rpcKeyBindingGeneration binding), binding) | binding <- bindings]
          )
  validateRegistry registry
  pure registry
 where
  makeBinding key = RpcKeyBinding key <$> logicalGeneration (rpcObservedNativeVersion key) <*> pure RpcKeyActive

registerRpcKey
  :: RpcObservedKey -> RpcKeyRegistry -> Either RpcKeyRegistryError (RpcKeyBinding, RpcKeyRegistry)
registerRpcKey observed registry = do
  validateRegistry registry
  case find sameNativeOrigin bindings of
    Just binding
      | rpcObservedPublicKey (rpcKeyBindingObserved binding) /= rpcObservedPublicKey observed ->
          Left RpcKeyOriginAliased
      | rpcKeyBindingStatus binding == RpcKeyRetired -> Left RpcKeyAlreadyRetired
      | otherwise -> Right (binding, registry)
    Nothing -> do
      when (length bindings >= rpcKeyRegistryMaximumBindings) (Left RpcKeyRegistryCapacityReached)
      when (any reusesPublic bindings) (Left RpcPublicKeyReused)
      when (any newerNative bindings) (Left RpcNativeVersionRegressed)
      watermark <-
        maybe (Left RpcKeyRegistryInvariantInvalid) Right (rpcKeyRegistryWatermark principal registry)
      generation <- logicalGeneration (watermark + 1)
      let binding = RpcKeyBinding observed generation RpcKeyActive
          next =
            registry
              { registryWatermarks = Map.insert principal (watermark + 1) (registryWatermarks registry)
              , registryBindings = Map.insert (principal, generation) binding (registryBindings registry)
              }
      validateRegistry next
      pure (binding, next)
 where
  principal = keyPrincipal observed
  bindings = rpcKeyRegistryBindings registry
  sameNativeOrigin binding =
    rpcObservedOrigin (rpcKeyBindingObserved binding) == rpcObservedOrigin observed
      && rpcObservedNativeVersion (rpcKeyBindingObserved binding) == rpcObservedNativeVersion observed
  reusesPublic = (== rpcObservedPublicKey observed) . rpcObservedPublicKey . rpcKeyBindingObserved
  newerNative binding =
    rpcObservedOrigin (rpcKeyBindingObserved binding) == rpcObservedOrigin observed
      && rpcObservedNativeVersion (rpcKeyBindingObserved binding) > rpcObservedNativeVersion observed

retireRpcKey
  :: CallerPrincipal
  -> SigningKeyGeneration
  -> RpcKeyRegistry
  -> Either RpcKeyRegistryError RpcKeyRegistry
retireRpcKey principal generation registry = do
  validateRegistry registry
  binding <-
    maybe
      (Left RpcKeyBindingMissing)
      Right
      (Map.lookup (principal, generation) (registryBindings registry))
  let retired = binding {bindingStatusValue = RpcKeyRetired}
      next =
        registry {registryBindings = Map.insert (principal, generation) retired (registryBindings registry)}
  validateRegistry next
  pure next

lookupActiveRpcKey
  :: RpcKeyOrigin -> Natural -> RpcKeyRegistry -> Either RpcKeyRegistryError RpcKeyBinding
lookupActiveRpcKey origin native registry = do
  validateRegistry registry
  binding <- maybe (Left RpcKeyBindingMissing) Right (find matches (rpcKeyRegistryBindings registry))
  case rpcKeyBindingStatus binding of
    RpcKeyActive -> Right binding
    RpcKeyRetired -> Left RpcKeyAlreadyRetired
 where
  matches binding = rpcObservedOrigin key == origin && rpcObservedNativeVersion key == native
   where
    key = rpcKeyBindingObserved binding

-- Selection is public metadata; it does not attest the native origin or grant
-- signing authority. All consumers still need their fresh native checks.
selectActiveRpcKeyForOrigin
  :: RpcKeyOrigin -> RpcKeyRegistry -> Either RpcKeyRegistryError RpcKeyBinding
selectActiveRpcKeyForOrigin origin registry = do
  validateRegistry registry
  case filter matches (rpcKeyRegistryBindings registry) of
    [] -> Left RpcKeyBindingMissing
    bindings@(_ : _) -> Right (maximumBy (comparing rpcKeyBindingGeneration) bindings)
 where
  matches binding =
    rpcKeyBindingStatus binding == RpcKeyActive
      && rpcObservedOrigin (rpcKeyBindingObserved binding) == origin

registeredRpcRouteTrust
  :: RuntimeRole -> Natural -> RpcKeyRegistry -> Either RpcKeyRegistryError RouteTrustRegistry
registeredRpcRouteTrust role maximumKeys registry = do
  validateRegistry registry
  entries <- concat <$> traverse routeEntries owned
  first RpcRouteTrustInvalid (mkRouteTrustRegistry role maximumKeys entries)
 where
  owned = filter ((== role) . controlPlaneRouteRole . fst) controlPlaneRouteCallerTopology
  routeEntries (route, callers) = concat <$> traverse (callerEntries route) callers
  callerEntries route principal = do
    let active =
          filter
            (\binding -> bindingPrincipal binding == principal && rpcKeyBindingStatus binding == RpcKeyActive)
            (rpcKeyRegistryBindings registry)
    when (null active) (Left (RpcCallerWithoutActiveKey principal))
    traverse (trustedEntry route principal) active
  trustedEntry route principal binding = do
    trusted <-
      first
        (const RpcPublicKeyInvalid)
        ( mkTrustedRequestKey
            principal
            (rpcKeyBindingGeneration binding)
            (rpcObservedPublicKey (rpcKeyBindingObserved binding))
        )
    pure (route, trusted)

validateRegistry :: RpcKeyRegistry -> Either RpcKeyRegistryError ()
validateRegistry registry = do
  unless (Map.keysSet marks == Set.fromList allCallerPrincipals) (Left RpcKeyRegistryInvariantInvalid)
  traverse_ (validateGeneration RpcLogicalGenerationInvalid) (Map.elems marks)
  when (length bindings > rpcKeyRegistryMaximumBindings) (Left RpcKeyRegistryCapacityReached)
  let nativeCoordinates =
        [ (rpcObservedOrigin key, rpcObservedNativeVersion key)
        | binding <- bindings
        , let key = rpcKeyBindingObserved binding
        ]
  unless
    (Set.fromList (map bindingPrincipal bindings) == Set.fromList allCallerPrincipals)
    (Left RpcKeyRegistryInvariantInvalid)
  unless (Set.size (Set.fromList nativeCoordinates) == length bindings) (Left RpcKeyOriginAliased)
  unless
    ( Set.size (Set.fromList (map (rpcObservedPublicKey . rpcKeyBindingObserved) bindings))
        == length bindings
    )
    (Left RpcPublicKeyReused)
  traverse_ checkEntry (Map.toList (registryBindings registry))
  seeds <- traverse checkHistory allCallerPrincipals
  unless (Set.size (Set.fromList seeds) == 1) (Left RpcLegacySeedOriginInvalid)
  traverse_
    checkOrder
    [ (left, right)
    | left <- bindings
    , right <- bindings
    , rpcObservedOrigin (rpcKeyBindingObserved left) == rpcObservedOrigin (rpcKeyBindingObserved right)
    , rpcObservedNativeVersion (rpcKeyBindingObserved left)
        < rpcObservedNativeVersion (rpcKeyBindingObserved right)
    ]
  checkEncodedBound registry
 where
  marks = registryWatermarks registry
  bindings = rpcKeyRegistryBindings registry
  checkEntry ((principal, generation), binding) = do
    unless
      (bindingPrincipal binding == principal && rpcKeyBindingGeneration binding == generation)
      (Left RpcKeyRegistryInvariantInvalid)
    validateGeneration RpcLogicalGenerationInvalid (signingKeyGenerationValue generation)
    unless
      (maybe False (>= signingKeyGenerationValue generation) (Map.lookup principal marks))
      (Left RpcKeyRegistryInvariantInvalid)
  checkHistory principal = do
    let owned = filter ((== principal) . bindingPrincipal) bindings
    case owned of
      [] -> Left RpcKeyRegistryInvariantInvalid
      seed : _ -> do
        watermark <- maybe (Left RpcKeyRegistryInvariantInvalid) Right (Map.lookup principal marks)
        let lowest = signingKeyGenerationValue (rpcKeyBindingGeneration seed)
            observed = rpcKeyBindingObserved seed
            origin = rpcObservedOrigin observed
        unless
          ( watermark >= lowest
              && fromIntegral (length owned) == watermark - lowest + 1
              && rpcKeyOriginScope origin == rpcKeyRegistryScope registry
              && rpcObservedNativeVersion observed == lowest
          )
          (Left RpcKeyRegistryInvariantInvalid)
        pure (rpcKeyOriginVault origin)
  checkOrder (left, right) =
    unless
      (rpcKeyBindingGeneration left < rpcKeyBindingGeneration right)
      (Left RpcKeyRegistryInvariantInvalid)

data OriginWire = OriginWire !Text !Text !Text
  deriving stock (Generic)
  deriving anyclass (Serialise)
data BindingWire = BindingWire !OriginWire !Natural !Natural !ByteString !RpcKeyBindingStatus
  deriving stock (Generic)
  deriving anyclass (Serialise)
data RegistryWire = RegistryWire !Word !Text ![(Word, Natural)] ![BindingWire]
  deriving stock (Generic)
  deriving anyclass (Serialise)

registryWire :: RpcKeyRegistry -> RegistryWire
registryWire registry =
  RegistryWire
    1
    (authorityScopeText (rpcKeyRegistryScope registry))
    [ (callerPrincipalCode principal, watermark)
    | (principal, watermark) <- Map.toAscList (registryWatermarks registry)
    ]
    (map bindingWire (rpcKeyRegistryBindings registry))
 where
  bindingWire binding =
    BindingWire
      ( OriginWire
          (authorityScopeText (rpcKeyOriginScope origin))
          (rpcVaultIncarnationText (rpcKeyOriginVault origin))
          (controlPlaneSigningKeyName (rpcKeyOriginRef origin))
      )
      (rpcObservedNativeVersion key)
      (signingKeyGenerationValue (rpcKeyBindingGeneration binding))
      (rpcObservedPublicKey key)
      (rpcKeyBindingStatus binding)
   where
    key = rpcKeyBindingObserved binding
    origin = rpcObservedOrigin key

checkEncodedBound :: RpcKeyRegistry -> Either RpcKeyRegistryError ()
checkEncodedBound registry =
  when
    (LazyByteString.length (serialise (registryWire registry)) > fromIntegral rpcKeyRegistryMaximumBytes)
    (Left RpcKeyRegistryTooLarge)

encodeRpcKeyRegistry :: RpcKeyRegistry -> Either RpcKeyRegistryError ByteString
encodeRpcKeyRegistry registry = do
  validateRegistry registry
  pure (LazyByteString.toStrict (serialise (registryWire registry)))

decodeRpcKeyRegistry :: ByteString -> Either RpcKeyRegistryError RpcKeyRegistry
decodeRpcKeyRegistry bytes = do
  let lazyBytes = LazyByteString.fromStrict bytes
  when
    (LazyByteString.length lazyBytes > fromIntegral rpcKeyRegistryMaximumBytes)
    (Left RpcKeyRegistryTooLarge)
  wire <- first (const RpcKeyRegistryWireInvalid) (deserialiseOrFail lazyBytes)
  unless (serialise wire == lazyBytes) (Left RpcKeyRegistryNonCanonical)
  registry <- restore wire
  validateRegistry registry
  unless
    (LazyByteString.toStrict (serialise (registryWire registry)) == bytes)
    (Left RpcKeyRegistryNonCanonical)
  pure registry
 where
  restore (RegistryWire version scope rawMarks rawBindings) = do
    unless (version == 1) (Left RpcKeyRegistryWireInvalid)
    parsedScope <- first (const RpcKeyRegistryWireInvalid) (mkAuthorityScope scope)
    marks <- traverse parseMark rawMarks
    bindings <- traverse parseBinding rawBindings
    unless (Map.size (Map.fromList marks) == length marks) (Left RpcKeyRegistryInvariantInvalid)
    let keyed = [((bindingPrincipal binding, rpcKeyBindingGeneration binding), binding) | binding <- bindings]
    unless (Map.size (Map.fromList keyed) == length keyed) (Left RpcKeyRegistryInvariantInvalid)
    pure (RpcKeyRegistry parsedScope (Map.fromList marks) (Map.fromList keyed))
  parseMark (code, value) = do
    principal <- maybe (Left RpcKeyRegistryWireInvalid) Right (callerPrincipalFromCode code)
    validateGeneration RpcLogicalGenerationInvalid value
    pure (principal, value)
  parseBinding (BindingWire (OriginWire scope vault ref) native logical public status) = do
    parsedScope <- first (const RpcKeyRegistryWireInvalid) (mkAuthorityScope scope)
    parsedVault <- mkRpcVaultIncarnation vault
    parsedRef <- maybe (Left RpcKeyRegistryWireInvalid) Right (controlPlaneSigningKeyRefFromName ref)
    key <- mkRpcObservedKey (mkRpcKeyOrigin parsedScope parsedVault parsedRef) native public
    generation <- logicalGeneration logical
    pure (RpcKeyBinding key generation status)
