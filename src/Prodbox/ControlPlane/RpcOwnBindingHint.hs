{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Bounded public discovery data for one external caller's own native origin.
-- A hint is untrusted: neither decoding nor selection constructs a signer or
-- authorizes an ordinary request. The bootstrap consumer separately attests the
-- native key and obtains the authenticated, independently pinned full registry.
module Prodbox.ControlPlane.RpcOwnBindingHint
  ( RpcOwnBindingQuery
  , mkRpcOwnBindingQuery
  , rpcOwnBindingQueryScope
  , rpcOwnBindingQueryOrigin
  , rpcOwnBindingQueryMaximumBytes
  , encodeRpcOwnBindingQuery
  , decodeRpcOwnBindingQuery
  , isRpcOwnBindingQuery
  , RpcOwnBindingHint
  , rpcOwnBindingHintObserved
  , rpcOwnBindingHintGeneration
  , rpcOwnBindingHintMaximumBytes
  , selectRpcOwnBindingHint
  , encodeRpcOwnBindingHint
  , decodeRpcOwnBindingHint
  , confirmRpcOwnBindingHintNative
  , confirmRpcOwnBindingHintRegistry
  , RpcOwnBindingHintError (..)
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticationRegistry
  ( controlPlaneSigningKeyName
  , controlPlaneSigningKeyPrincipal
  , controlPlaneSigningKeyRefFromName
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (..)
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope, authorityScopeText, mkAuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication
  ( SigningKeyGeneration
  , mkSigningKeyGeneration
  , signingKeyGenerationValue
  )
import Prodbox.ControlPlane.RpcKeyRegistry

data RpcOwnBindingQuery = RpcOwnBindingQuery !AuthorityScope !RpcKeyOrigin
  deriving stock (Eq, Show)

data RpcOwnBindingHint = RpcOwnBindingHint !AuthorityScope !RpcObservedKey !SigningKeyGeneration
  deriving stock (Eq, Show)

data QueryWire = QueryWire !Word !Text !Text !Text !Text
  deriving stock (Generic)
  deriving anyclass (Serialise)

data HintWire = HintWire !Word !QueryWire !Natural !Natural !ByteString
  deriving stock (Generic)
  deriving anyclass (Serialise)

data RpcOwnBindingHintError
  = RpcOwnBindingWireInvalid
  | RpcOwnBindingTooLarge
  | RpcOwnBindingScopeMismatch
  | RpcOwnBindingCallerRefused
  | RpcOwnBindingOriginInvalid
  | RpcOwnBindingNativeMismatch
  | RpcOwnBindingChanged
  | RpcOwnBindingRegistryRefused !RpcKeyRegistryError
  deriving stock (Eq, Show)

-- Two independently bounded 2,048-character scope fields may use four UTF-8
-- bytes per character. These ceilings include that case and canonical framing;
-- neither bound admits a complete registry or any inner Authority payload.
rpcOwnBindingQueryMaximumBytes, rpcOwnBindingHintMaximumBytes :: Int
rpcOwnBindingQueryMaximumBytes = 20 * 1024
rpcOwnBindingHintMaximumBytes = 21 * 1024

queryPrefix, hintPrefix :: ByteString
queryPrefix = "prodbox-rpc-own-binding/v1\NUL"
hintPrefix = "prodbox-rpc-own-binding-response/v1\NUL"

isRpcOwnBindingQuery :: ByteString -> Bool
isRpcOwnBindingQuery = BS.isPrefixOf queryPrefix

mkRpcOwnBindingQuery
  :: AuthorityScope -> RpcKeyOrigin -> Either RpcOwnBindingHintError RpcOwnBindingQuery
mkRpcOwnBindingQuery scope origin = do
  let ref = rpcKeyOriginRef origin
  unless
    (controlPlaneSigningKeyRefFromName (controlPlaneSigningKeyName ref) == Just ref)
    (Left RpcOwnBindingOriginInvalid)
  case controlPlaneSigningKeyPrincipal ref of
    CallerOperatorCli -> pure ()
    CallerTestHarness -> pure ()
    CallerService _ -> Left RpcOwnBindingCallerRefused
    CallerAdminActionRunner -> Left RpcOwnBindingCallerRefused
    CallerCredentialProvisioner -> Left RpcOwnBindingCallerRefused
    CallerCredentialProvisionerCompletion -> Left RpcOwnBindingCallerRefused
  pure (RpcOwnBindingQuery scope origin)

rpcOwnBindingQueryScope :: RpcOwnBindingQuery -> AuthorityScope
rpcOwnBindingQueryScope (RpcOwnBindingQuery scope _) = scope

rpcOwnBindingQueryOrigin :: RpcOwnBindingQuery -> RpcKeyOrigin
rpcOwnBindingQueryOrigin (RpcOwnBindingQuery _ origin) = origin

queryWire :: RpcOwnBindingQuery -> QueryWire
queryWire (RpcOwnBindingQuery scope origin) =
  QueryWire
    1
    (authorityScopeText scope)
    (authorityScopeText (rpcKeyOriginScope origin))
    (rpcVaultIncarnationText (rpcKeyOriginVault origin))
    (controlPlaneSigningKeyName (rpcKeyOriginRef origin))

encodeRpcOwnBindingQuery :: RpcOwnBindingQuery -> ByteString
encodeRpcOwnBindingQuery = (queryPrefix <>) . Lazy.toStrict . serialise . queryWire

decodeRpcOwnBindingQuery
  :: AuthorityScope -> ByteString -> Either RpcOwnBindingHintError RpcOwnBindingQuery
decodeRpcOwnBindingQuery scope bytes = do
  wire <- decodeWire rpcOwnBindingQueryMaximumBytes queryPrefix bytes
  decodeQueryWire scope wire

decodeQueryWire
  :: AuthorityScope -> QueryWire -> Either RpcOwnBindingHintError RpcOwnBindingQuery
decodeQueryWire expected (QueryWire version rawScope rawOriginScope rawVault rawRef) = do
  unless (version == 1) (Left RpcOwnBindingWireInvalid)
  scope <- scopeFromWire rawScope
  unless (scope == expected) (Left RpcOwnBindingScopeMismatch)
  originScope <- scopeFromWire rawOriginScope
  vault <- first (const RpcOwnBindingOriginInvalid) (mkRpcVaultIncarnation rawVault)
  ref <- maybe (Left RpcOwnBindingOriginInvalid) Right (controlPlaneSigningKeyRefFromName rawRef)
  mkRpcOwnBindingQuery scope (mkRpcKeyOrigin originScope vault ref)

scopeFromWire :: Text -> Either RpcOwnBindingHintError AuthorityScope
scopeFromWire raw = do
  scope <- first (const RpcOwnBindingOriginInvalid) (mkAuthorityScope raw)
  unless (authorityScopeText scope == raw) (Left RpcOwnBindingWireInvalid)
  pure scope

rpcOwnBindingHintObserved :: RpcOwnBindingHint -> RpcObservedKey
rpcOwnBindingHintObserved (RpcOwnBindingHint _ observed _) = observed

rpcOwnBindingHintGeneration :: RpcOwnBindingHint -> SigningKeyGeneration
rpcOwnBindingHintGeneration (RpcOwnBindingHint _ _ generation) = generation

selectRpcOwnBindingHint
  :: RpcOwnBindingQuery -> RpcKeyRegistry -> Either RpcOwnBindingHintError RpcOwnBindingHint
selectRpcOwnBindingHint (RpcOwnBindingQuery scope origin) registry = do
  unless (rpcKeyRegistryScope registry == scope) (Left RpcOwnBindingScopeMismatch)
  binding <- first RpcOwnBindingRegistryRefused (selectActiveRpcKeyForOrigin origin registry)
  pure (RpcOwnBindingHint scope (rpcKeyBindingObserved binding) (rpcKeyBindingGeneration binding))

encodeRpcOwnBindingHint :: RpcOwnBindingHint -> ByteString
encodeRpcOwnBindingHint (RpcOwnBindingHint scope observed generation) =
  hintPrefix
    <> Lazy.toStrict
      ( serialise
          ( HintWire
              1
              (queryWire (RpcOwnBindingQuery scope (rpcObservedOrigin observed)))
              (rpcObservedNativeVersion observed)
              (signingKeyGenerationValue generation)
              (rpcObservedPublicKey observed)
          )
      )

decodeRpcOwnBindingHint
  :: RpcOwnBindingQuery -> ByteString -> Either RpcOwnBindingHintError RpcOwnBindingHint
decodeRpcOwnBindingHint query bytes = do
  HintWire version wire native logical public <-
    decodeWire rpcOwnBindingHintMaximumBytes hintPrefix bytes
  unless (version == 1) (Left RpcOwnBindingWireInvalid)
  actual <- decodeQueryWire (rpcOwnBindingQueryScope query) wire
  unless (actual == query) (Left RpcOwnBindingOriginInvalid)
  observed <-
    first
      (const RpcOwnBindingWireInvalid)
      (mkRpcObservedKey (rpcOwnBindingQueryOrigin query) native public)
  unless (logical > 0 && logical <= 2 ^ (64 :: Int) - 1) (Left RpcOwnBindingWireInvalid)
  generation <- first (const RpcOwnBindingWireInvalid) (mkSigningKeyGeneration logical)
  pure (RpcOwnBindingHint (rpcOwnBindingQueryScope query) observed generation)

decodeWire
  :: (Serialise wire)
  => Int -> ByteString -> ByteString -> Either RpcOwnBindingHintError wire
decodeWire maximumBytes prefix bytes = do
  unless (BS.length bytes <= maximumBytes) (Left RpcOwnBindingTooLarge)
  body <- maybe (Left RpcOwnBindingWireInvalid) Right (BS.stripPrefix prefix bytes)
  wire <- first (const RpcOwnBindingWireInvalid) (deserialiseOrFail (Lazy.fromStrict body))
  unless (Lazy.toStrict (serialise wire) == body) (Left RpcOwnBindingWireInvalid)
  pure wire

-- These are comparisons of public data. Even two successful comparisons are
-- not a native observation, authenticated registry read or signing capability.
confirmRpcOwnBindingHintNative
  :: RpcOwnBindingHint
  -> RpcKeyOrigin
  -> (Natural, ByteString)
  -> Either RpcOwnBindingHintError ()
confirmRpcOwnBindingHintNative (RpcOwnBindingHint _ observed _) origin (version, public) =
  unless
    ( rpcObservedOrigin observed == origin
        && rpcObservedNativeVersion observed == version
        && rpcObservedPublicKey observed == public
    )
    (Left RpcOwnBindingNativeMismatch)

confirmRpcOwnBindingHintRegistry
  :: RpcOwnBindingHint -> RpcKeyRegistry -> Either RpcOwnBindingHintError RpcKeyBinding
confirmRpcOwnBindingHintRegistry hint@(RpcOwnBindingHint scope observed generation) registry = do
  query <- mkRpcOwnBindingQuery scope (rpcObservedOrigin observed)
  current <- selectRpcOwnBindingHint query registry
  unless (current == hint) (Left RpcOwnBindingChanged)
  binding <-
    first
      RpcOwnBindingRegistryRefused
      (lookupActiveRpcKey (rpcObservedOrigin observed) (rpcObservedNativeVersion observed) registry)
  unless (rpcKeyBindingGeneration binding == generation) (Left RpcOwnBindingChanged)
  pure binding
