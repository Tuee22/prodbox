{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

-- | Public metadata only. This program has no mutation or secret-read effect.
module Prodbox.ControlPlane.AuthorityPeerContext
  ( AuthorityPeerContext
  , peerContextScope
  , peerContextEpoch
  , peerContextIssuer
  , peerContextPublicKey
  , AuthorityPeerContextError (..)
  , AuthorityPeerContextProgram (..)
  , AuthorityPeerContextInterpreter (..)
  , authorityPeerContextMaximumBytes
  , authorityPeerContextRequest
  , isAuthorityPeerContextRequest
  , encodeAuthorityPeerContextResponse
  , decodeAuthorityPeerContextResponse
  , observeAuthorityPeerContext
  )
where

import Codec.Serialise (Serialise)
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope, authorityScopeText, mkAuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication
  ( VerifiedControlPlaneRequest
  , verifiedRequestAuthorityEpoch
  , verifiedRequestAuthorityScope
  , verifiedRequestBody
  , verifiedRequestCalleeRole
  , verifiedRequestDeadline
  , verifiedRequestRoute
  )
import Prodbox.ControlPlane.Route (ControlPlaneRoute (LifecycleAuthorityPeerObserve))
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetIntentPublicKey
  , TargetIssuerKeyGeneration
  , mkTargetIntentPublicKey
  , mkTargetIssuerKeyGeneration
  , targetIntentPublicKeyBytes
  , targetIssuerKeyGenerationValue
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityEpoch
  , authorityEpochFromValue
  , authorityEpochValue
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data AuthorityPeerContext = AuthorityPeerContext
  { peerContextScope :: !AuthorityScope
  , peerContextEpoch :: !AuthorityEpoch
  , peerContextIssuer :: !TargetIssuerKeyGeneration
  , peerContextPublicKey :: !TargetIntentPublicKey
  }
  deriving stock (Eq, Show)

data AuthorityPeerContextError
  = PeerContextRequestInvalid
  | PeerContextBindingInvalid
  | PeerContextClockUnavailable
  | PeerContextEpochUnavailable
  | PeerContextIssuerUnavailable
  | PeerContextDeadlineReached
  | PeerContextEffectTimedOut
  | PeerContextFactsChanged
  | PeerContextRequestEpochAhead
  | PeerContextResponseInvalid
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityPeerContextProgram result where
  ReadPeerContextTime :: AuthorityPeerContextProgram AuthorityTime
  ReadPeerContextEpoch :: AuthorityTime -> AuthorityPeerContextProgram AuthorityEpoch
  ReadPeerContextIssuer
    :: AuthorityTime
    -> AuthorityPeerContextProgram (TargetIssuerKeyGeneration, TargetIntentPublicKey)

newtype AuthorityPeerContextInterpreter m = AuthorityPeerContextInterpreter
  { runAuthorityPeerContextProgram
      :: forall result
       . AuthorityPeerContextProgram result
      -> m (Either AuthorityPeerContextError result)
  }

data PeerContextRequest = ObserveAuthorityPeerContext
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data PeerContextResponseWire
  = PeerContextObservedWire !Text !Natural !Natural !ByteString
  | PeerContextRefusedWire !AuthorityPeerContextError
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

authorityPeerContextMaximumBytes :: Int
authorityPeerContextMaximumBytes = 1024

authorityPeerContextRequest :: ByteString
authorityPeerContextRequest = LazyByteString.toStrict (encodeControlPlaneRequest ObserveAuthorityPeerContext)

isAuthorityPeerContextRequest :: ByteString -> Bool
isAuthorityPeerContextRequest bytes =
  case decodeControlPlaneRequest 64 (LazyByteString.fromStrict bytes) of
    Right ObserveAuthorityPeerContext -> True
    Left _ -> False

encodeAuthorityPeerContextResponse
  :: Either AuthorityPeerContextError AuthorityPeerContext -> ByteString
encodeAuthorityPeerContextResponse result
  | ByteString.length encoded <= authorityPeerContextMaximumBytes = encoded
  | otherwise = encodePeerContextResult (Left PeerContextResponseInvalid)
 where
  encoded = encodePeerContextResult result

encodePeerContextResult :: Either AuthorityPeerContextError AuthorityPeerContext -> ByteString
encodePeerContextResult result = LazyByteString.toStrict (encodeControlPlaneResponse wire)
 where
  wire = case result of
    Left err -> PeerContextRefusedWire err
    Right context ->
      PeerContextObservedWire
        (authorityScopeText (peerContextScope context))
        (authorityEpochValue (peerContextEpoch context))
        (targetIssuerKeyGenerationValue (peerContextIssuer context))
        (targetIntentPublicKeyBytes (peerContextPublicKey context))

decodeAuthorityPeerContextResponse
  :: ByteString -> Either AuthorityPeerContextError AuthorityPeerContext
decodeAuthorityPeerContextResponse bytes = do
  wire <-
    first
      (const PeerContextResponseInvalid)
      (decodeControlPlaneResponse authorityPeerContextMaximumBytes (LazyByteString.fromStrict bytes))
  case wire of
    PeerContextRefusedWire err -> Left err
    PeerContextObservedWire scope epoch generation public -> do
      parsedScope <- first (const PeerContextResponseInvalid) (mkAuthorityScope scope)
      parsedEpoch <- maybe (Left PeerContextResponseInvalid) Right (authorityEpochFromValue epoch)
      issuer <- first (const PeerContextResponseInvalid) (mkTargetIssuerKeyGeneration generation)
      key <- first (const PeerContextResponseInvalid) (mkTargetIntentPublicKey public)
      pure (AuthorityPeerContext parsedScope parsedEpoch issuer key)

observeAuthorityPeerContext
  :: (Monad m)
  => AuthorityScope
  -> AuthorityPeerContextInterpreter m
  -> VerifiedControlPlaneRequest
  -> m (Either AuthorityPeerContextError AuthorityPeerContext)
observeAuthorityPeerContext expectedScope interpreter verified = runExceptT $ do
  unless
    ( verifiedRequestRoute verified == LifecycleAuthorityPeerObserve
        && verifiedRequestCalleeRole verified == LifecycleAuthorityRuntime
        && verifiedRequestAuthorityScope verified == expectedScope
    )
    (throwE PeerContextBindingInvalid)
  unless
    (isAuthorityPeerContextRequest (verifiedRequestBody verified))
    (throwE PeerContextRequestInvalid)
  checkTime
  epoch <- ExceptT (runAuthorityPeerContextProgram interpreter (ReadPeerContextEpoch deadline))
  issuer <- ExceptT (runAuthorityPeerContextProgram interpreter (ReadPeerContextIssuer deadline))
  checkTime
  closingEpoch <- ExceptT (runAuthorityPeerContextProgram interpreter (ReadPeerContextEpoch deadline))
  closingIssuer <-
    ExceptT (runAuthorityPeerContextProgram interpreter (ReadPeerContextIssuer deadline))
  checkTime
  unless (epoch == closingEpoch && issuer == closingIssuer) (throwE PeerContextFactsChanged)
  unless
    (verifiedRequestAuthorityEpoch verified <= closingEpoch)
    (throwE PeerContextRequestEpochAhead)
  let (generation, public) = issuer
  let context = AuthorityPeerContext expectedScope epoch generation public
  unless
    (ByteString.length (encodePeerContextResult (Right context)) <= authorityPeerContextMaximumBytes)
    (throwE PeerContextResponseInvalid)
  checkTime
  pure context
 where
  deadline = verifiedRequestDeadline verified
  checkTime = do
    now <- ExceptT (runAuthorityPeerContextProgram interpreter ReadPeerContextTime)
    unless (now < deadline) (throwE PeerContextDeadlineReached)
