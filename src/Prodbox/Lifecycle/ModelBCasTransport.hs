{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.51 Increment B (Stage B): the ONE shared Model-B ↔ authority-object
-- CAS translation both retained-authority transports delegate to.
--
-- 'gatewayModelBCasAdapter' (the in-cluster gateway HTTP client) and
-- 'Prodbox.Lifecycle.HostDirectAuthorityStore.hostDirectModelBCasAdapter' (the
-- host-direct CLI reaching MinIO through 'Prodbox.Lifecycle.AuthorityObjectCore')
-- are BOTH partial applications of 'modelBCasAdapterOverTransport' over an
-- injected 'ModelBTransport'. The coordinate-authority guard, guard-coordinate
-- validation, payload encode/decode, and every 'ModelBObservation' /
-- 'ModelBCasResult' response mapping live here exactly once, so the two transports
-- cannot silently diverge into disjoint Model-B translation behaviour. This
-- extends the Stage-A structural byte-compat (shared 'AuthorityObjectCore') one
-- level up: there is no second hand-maintained Model-B↔AuthorityObject copy.
module Prodbox.Lifecycle.ModelBCasTransport
  ( ModelBTransport (..)
  , modelBCasAdapterOverTransport
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Gateway.ObjectStore
  ( AuthorityObjectCasRequest (..)
  , AuthorityObjectCasResponse (..)
  , AuthorityObjectLeaseGuard (..)
  , AuthorityObjectObservation (..)
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBLeaseGuard (..)
  , ModelBObjectCoordinate
  , ModelBObservation (..)
  , mkModelBObjectVersion
  , modelBObjectAuthority
  , modelBObjectLogicalName
  , modelBObjectVersionText
  )

-- | The injected authority-object transport. Both transports reach the SAME
-- sealed retained-authority objects; only the path differs — the gateway
-- transport goes over the daemon's loopback-verified NodePort HTTP surface, the
-- host-direct transport reaches MinIO in-process through
-- 'Prodbox.Lifecycle.AuthorityObjectCore'. Errors are normalised to 'Text' so the
-- shared adapter maps them identically to 'ModelBUnobservable' /
-- 'ModelBCasUnobservable', exactly as the pre-Stage-B gateway adapter did.
data ModelBTransport = ModelBTransport
  { transportObserveObject
      :: !(Text -> IO (Either Text AuthorityObjectObservation))
  , transportCasObject
      :: !(AuthorityObjectCasRequest -> IO (Either Text AuthorityObjectCasResponse))
  }

-- | Build a lifetime-indexed Model-B CAS adapter over an injected transport. The
-- body is lifted verbatim from the pre-Stage-B @gatewayModelBCasAdapter@: it
-- validates that the target (and any guard) coordinate belongs to the configured
-- authority, encodes the payload, delegates the read / conditional write to the
-- transport, and maps the flat authority-object observation/response back into the
-- typed 'ModelBObservation' / 'ModelBCasResult'.
modelBCasAdapterOverTransport
  :: LongLivedCheckpointAuthority
  -> ModelBTransport
  -> ModelBCodec value
  -> ModelBCasAdapter l IO value
modelBCasAdapterOverTransport authority transport codec =
  ModelBCasAdapter
    { modelBObserve = observe
    , modelBCompareAndSwap = compareAndSwap
    }
 where
  observe coordinate =
    case validateCoordinateAuthority authority coordinate of
      Left err -> pure (ModelBUnobservable (Text.pack err))
      Right () -> do
        result <- transportObserveObject transport (modelBObjectLogicalName coordinate)
        pure $ case result of
          Left err -> ModelBUnobservable err
          Right observation -> decodeObservation codec observation

  compareAndSwap request =
    case requestParts authority request of
      Left err -> pure (ModelBCasUnobservable (Text.pack err))
      Right (coordinate, expectedVersion, maybeGuard, value) ->
        case validateCoordinateAuthority authority coordinate of
          Left err -> pure (ModelBCasUnobservable (Text.pack err))
          Right () ->
            case encodeModelBValue codec value of
              Left err -> pure (ModelBCasRefusedCorrupt (Text.pack err))
              Right encodedValue -> do
                let casRequest =
                      AuthorityObjectCasRequest
                        { authorityObjectCasLogicalName = modelBObjectLogicalName coordinate
                        , authorityObjectCasExpectedVersion = expectedVersion
                        , authorityObjectCasLeaseGuard = authorityObjectLeaseGuard <$> maybeGuard
                        , authorityObjectCasPayload = encodedValue
                        , -- Consumed only by the daemon's server-side NodePort admission
                          -- check; the host-direct core ignores it. The gateway transport
                          -- re-derives it at the loopback boundary, so this value is inert.
                          authorityObjectCasLoopbackNodePortVerified = True
                        }
                result <- transportCasObject transport casRequest
                pure $ case result of
                  Left err -> ModelBCasUnobservable err
                  Right (AuthorityObjectCasApplied versionText) ->
                    case mkModelBObjectVersion versionText of
                      Left err -> ModelBCasUnobservable (Text.pack (show err))
                      Right version -> ModelBCasApplied version value
                  Right (AuthorityObjectCasConflict observation) ->
                    ModelBCasConflict (decodeObservation codec observation)

-- | Decompose a request into (target coordinate, expected version, optional lease
-- guard, payload), validating that any guard's lease coordinate belongs to the
-- configured authority — lifted verbatim from the pre-Stage-B gateway adapter.
requestParts
  :: LongLivedCheckpointAuthority
  -> ModelBCasRequest l value
  -> Either
       String
       (ModelBObjectCoordinate l, Maybe Text, Maybe ModelBLeaseGuard, value)
requestParts authority request =
  case request of
    ModelBInitialize coordinate value ->
      Right (coordinate, Nothing, Nothing, value)
    ModelBReplace coordinate version value ->
      Right (coordinate, Just (modelBObjectVersionText version), Nothing, value)
    ModelBInitializeGuarded coordinate guard value ->
      case validateCoordinateAuthority authority (modelBLeaseGuardCoordinate guard) of
        Left err -> Left err
        Right () -> Right (coordinate, Nothing, Just guard, value)
    ModelBReplaceGuarded coordinate version guard value ->
      case validateCoordinateAuthority authority (modelBLeaseGuardCoordinate guard) of
        Left err -> Left err
        Right () ->
          Right
            ( coordinate
            , Just (modelBObjectVersionText version)
            , Just guard
            , value
            )

-- | The coordinate-authority guard, previously @coordinateEndpoint@ minus the
-- endpoint (the transport now owns endpoint selection). The refusal string is
-- byte-identical to the pre-Stage-B adapter's.
validateCoordinateAuthority
  :: LongLivedCheckpointAuthority -> ModelBObjectCoordinate l -> Either String ()
validateCoordinateAuthority expected coordinate
  | modelBObjectAuthority coordinate /= expected =
      Left "Model-B coordinate does not belong to the configured long-lived checkpoint authority"
  | otherwise = Right ()

-- | Project a typed 'ModelBLeaseGuard' onto the flat wire lease guard — lifted
-- verbatim from the pre-Stage-B gateway adapter.
authorityObjectLeaseGuard :: ModelBLeaseGuard -> AuthorityObjectLeaseGuard
authorityObjectLeaseGuard guard =
  AuthorityObjectLeaseGuard
    { authorityLeaseGuardLogicalName =
        modelBObjectLogicalName (modelBLeaseGuardCoordinate guard)
    , authorityLeaseGuardExpectedVersion =
        modelBObjectVersionText (modelBLeaseGuardExpectedVersion guard)
    , authorityLeaseGuardOwnerNonce = modelBLeaseGuardOwnerNonceText guard
    , authorityLeaseGuardFencingToken =
        modelBLeaseGuardFencingTokenValue guard
    }

-- | Map a flat authority-object observation back into a typed 'ModelBObservation'
-- — lifted verbatim from the pre-Stage-B gateway adapter.
decodeObservation
  :: ModelBCodec value
  -> AuthorityObjectObservation
  -> ModelBObservation value
decodeObservation codec observation =
  case observation of
    AuthorityObjectMissing -> ModelBMissing
    AuthorityObjectObserved versionText payload ->
      case (mkModelBObjectVersion versionText, decodeModelBValue codec payload) of
        (Left err, _) -> ModelBUnobservable (Text.pack (show err))
        (_, Left err) -> ModelBCorrupt (Text.pack err)
        (Right version, Right value) -> ModelBObserved version value
