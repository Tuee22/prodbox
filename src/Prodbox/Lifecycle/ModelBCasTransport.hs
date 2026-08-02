{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.51 Increment B (Stage B): the ONE shared Model-B ↔ authority-object
-- CAS translation both retained-authority transports delegate to.
--
-- The admitted Lifecycle Authority store and the pre-Authority bootstrap store
-- are both partial applications of 'modelBCasAdapterOverTransport' over an
-- injected 'ModelBTransport'. The coordinate-authority guard, guard-coordinate
-- validation, payload encode/decode, and every 'ModelBObservation' /
-- 'ModelBCasResult' response mapping live here exactly once, so the transports
-- cannot silently diverge into disjoint Model-B translation behaviour.
module Prodbox.Lifecycle.ModelBCasTransport
  ( ModelBTransport (..)
  , modelBCasAdapterOverTransport
  , transportFailureObservation
  , transportFailureCasResult
  , modelBEndpointUnreadyFragments
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityObject
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
import Prodbox.Service (isRetryableTransientFailure)

-- | The injected authority-object transport. Production authority and bounded
-- bootstrap transports reach the same sealed retained-authority objects. Errors
-- are normalised to 'Text' so the shared adapter maps them identically to
-- 'ModelBUnobservable' / 'ModelBCasUnobservable'.
data ModelBTransport = ModelBTransport
  { transportObserveObject
      :: !(Text -> IO (Either Text AuthorityObjectObservation))
  , transportCasObject
      :: !(AuthorityObjectCasRequest -> IO (Either Text AuthorityObjectCasResponse))
  }

-- | Classify a transport read failure into the typed three-valued observation:
-- a transient endpoint-unreachability (a not-yet-routable port-forward / NodePort,
-- e.g. a connection-refused or the aws-CLI "could not connect to the endpoint URL"
-- phrase) becomes the retryable, gate-closed 'ModelBEndpointUnready', while any
-- other read failure (decode/auth/HMAC/etc.) stays the terminal 'ModelBUnobservable'.
-- Retryability is a total function of the shared 'Prodbox.Service' transient table
-- plus the object-store-specific fragments, never a hand-set flag at the call site.
transportFailureObservation :: Text -> ModelBObservation value
transportFailureObservation err
  | isRetryableTransientFailure modelBEndpointUnreadyFragments (Text.unpack err) =
      ModelBEndpointUnready err
  | otherwise = ModelBUnobservable err

-- | Object-store-specific transient fragments beyond the shared
-- 'Prodbox.Service.transientFailureFragments' base.  The base already carries
-- @"connection refused"@; these add the aws-CLI phrasing that the base omits.
modelBEndpointUnreadyFragments :: [String]
modelBEndpointUnreadyFragments =
  [ "could not connect to the endpoint"
  , "could not connect"
  ]

-- | Classify a transport write failure, the CAS-path analogue of
-- 'transportFailureObservation': a transient endpoint-unreachability becomes the
-- retryable 'ModelBCasEndpointUnready', anything else the terminal
-- 'ModelBCasUnobservable'.
transportFailureCasResult :: Text -> ModelBCasResult value
transportFailureCasResult err
  | isRetryableTransientFailure modelBEndpointUnreadyFragments (Text.unpack err) =
      ModelBCasEndpointUnready err
  | otherwise = ModelBCasUnobservable err

-- | Build a lifetime-indexed Model-B CAS adapter over an injected transport. The
-- body validates that the target (and any guard) coordinate belongs to the configured
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
          Left err -> transportFailureObservation err
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
                        , -- Consumed by the in-cluster Authority server's
                          -- admission check. The typed transport establishes
                          -- this invariant before the request reaches the core.
                          authorityObjectCasLoopbackNodePortVerified = True
                        }
                result <- transportCasObject transport casRequest
                pure $ case result of
                  Left err -> transportFailureCasResult err
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
