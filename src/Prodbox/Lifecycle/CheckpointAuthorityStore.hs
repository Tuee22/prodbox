{-# LANGUAGE ImportQualifiedPost #-}

-- | Production gateway-backed Model-B compare-and-swap adapter for retained
-- lease, intent, SMTP projection, and fenced Pulumi checkpoint objects.
-- Coordinates carry the retained control-plane endpoint explicitly; this
-- module never consults an ambient kube context or selected target sink.
module Prodbox.Lifecycle.CheckpointAuthorityStore
  ( ModelBCodec (..)
  , gatewayModelBCasAdapter
  )
where

import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Prodbox.Gateway.Client qualified as GatewayClient
import Prodbox.Gateway.ObjectStore
  ( AuthorityObjectCasResponse (..)
  , AuthorityObjectLeaseGuard (..)
  , AuthorityObjectObservation (..)
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBLeaseGuard (..)
  , ModelBObjectCoordinate
  , ModelBObservation (..)
  , checkpointAuthorityGatewayEndpoint
  , mkModelBObjectVersion
  , modelBObjectAuthority
  , modelBObjectLogicalName
  , modelBObjectVersionText
  )

-- | Payload codec supplied by the state-machine owner. Decode failures are
-- corruption evidence; transport/CAS failures remain unobservable.
data ModelBCodec value = ModelBCodec
  { encodeModelBValue :: value -> Either String ByteString
  , decodeModelBValue :: ByteString -> Either String value
  }

gatewayModelBCasAdapter
  :: LongLivedCheckpointAuthority
  -> ModelBCodec value
  -> ModelBCasAdapter IO value
gatewayModelBCasAdapter authority codec =
  ModelBCasAdapter
    { modelBObserve = observe
    , modelBCompareAndSwap = compareAndSwap
    }
 where
  observe coordinate =
    case coordinateEndpoint authority coordinate of
      Left err -> pure (ModelBUnobservable (Text.pack err))
      Right endpoint -> do
        result <-
          GatewayClient.getAuthorityObject
            endpoint
            (modelBObjectLogicalName coordinate)
        pure $ case result of
          Left err -> ModelBUnobservable (Text.pack (GatewayClient.renderGatewayError err))
          Right observation -> decodeObservation codec observation

  compareAndSwap request =
    case requestParts request of
      Left err -> pure (ModelBCasUnobservable (Text.pack err))
      Right (coordinate, expectedVersion, maybeGuard, value) ->
        case coordinateEndpoint authority coordinate of
          Left err -> pure (ModelBCasUnobservable (Text.pack err))
          Right endpoint ->
            case encodeModelBValue codec value of
              Left err -> pure (ModelBCasRefusedCorrupt (Text.pack err))
              Right encodedValue -> do
                result <-
                  case maybeGuard of
                    Nothing ->
                      GatewayClient.compareAndSwapAuthorityObject
                        endpoint
                        (modelBObjectLogicalName coordinate)
                        expectedVersion
                        encodedValue
                    Just guard ->
                      GatewayClient.compareAndSwapAuthorityObjectGuarded
                        endpoint
                        (modelBObjectLogicalName coordinate)
                        expectedVersion
                        (authorityObjectLeaseGuard guard)
                        encodedValue
                pure $ case result of
                  Left err ->
                    ModelBCasUnobservable (Text.pack (GatewayClient.renderGatewayError err))
                  Right (AuthorityObjectCasApplied versionText) ->
                    case mkModelBObjectVersion versionText of
                      Left err -> ModelBCasUnobservable (Text.pack (show err))
                      Right version -> ModelBCasApplied version value
                  Right (AuthorityObjectCasConflict observation) ->
                    ModelBCasConflict (decodeObservation codec observation)

  requestParts request =
    case request of
      ModelBInitialize coordinate value -> Right (coordinate, Nothing, Nothing, value)
      ModelBReplace coordinate version value ->
        Right (coordinate, Just (modelBObjectVersionText version), Nothing, value)
      ModelBInitializeGuarded coordinate guard value ->
        case coordinateEndpoint authority (modelBLeaseGuardCoordinate guard) of
          Left err -> Left err
          Right _ -> Right (coordinate, Nothing, Just guard, value)
      ModelBReplaceGuarded coordinate version guard value ->
        case coordinateEndpoint authority (modelBLeaseGuardCoordinate guard) of
          Left err -> Left err
          Right _ ->
            Right
              ( coordinate
              , Just (modelBObjectVersionText version)
              , Just guard
              , value
              )

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

coordinateEndpoint
  :: LongLivedCheckpointAuthority
  -> ModelBObjectCoordinate
  -> Either String String
coordinateEndpoint expected coordinate
  | modelBObjectAuthority coordinate /= expected =
      Left "Model-B coordinate does not belong to the configured long-lived checkpoint authority"
  | otherwise =
      Right (Text.unpack (checkpointAuthorityGatewayEndpoint expected))

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
