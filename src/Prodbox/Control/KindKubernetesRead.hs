{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Narrow read-only Kubernetes transport for the selected kind endpoint.
-- The caller must independently bind the configured CA to the owned cluster.
module Prodbox.Control.KindKubernetesRead
  ( KindKubernetesReaderError (..)
  , observeKindKubernetesVolumeBinding
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (Value, eitherDecodeStrict')
import Data.ByteString qualified as ByteString
import Data.X509
  ( AltName (AltNameIP)
  , Certificate
  , ExtKeyUsagePurpose (KeyUsagePurpose_ServerAuth)
  , ExtSubjectAltName (..)
  , HashALG (HashSHA256)
  , certExtensions
  , extensionGet
  )
import Data.X509.Validation
  ( FailedReason (NameMismatch)
  , ValidationChecks (..)
  , ValidationHooks (..)
  , defaultChecks
  , defaultHooks
  , validate
  )
import Network.Connection (TLSSettings (TLSSettings))
import Network.HTTP.Client
  ( BodyReader
  , HttpException
  , Manager
  , ManagerSettings (..)
  , Request (..)
  , brRead
  , managerSetMaxHeaderLength
  , managerSetMaxNumberHeaders
  , managerSetProxy
  , newManager
  , noProxy
  , parseRequest
  , responseBody
  , responseStatus
  , responseTimeoutMicro
  , withResponse
  )
import Network.HTTP.Client.TLS (mkManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Network.TLS
  ( ClientHooks (..)
  , ClientParams (..)
  , DebugParams (..)
  , Shared (..)
  , defaultParamsClient
  )
import Prodbox.Config.DeploymentScope (DeploymentScope)
import Prodbox.Config.KindVolume (KindVolume, kindVolumeName, kindVolumeNamespace, kindVolumeScope)
import Prodbox.Control.KindKubeconfig (KindKubeconfig, kindKubeconfigScope, kindKubeconfigServer)
import Prodbox.Control.KindKubeconfigTls
  ( KindTlsMaterialError
  , parseKindTlsMaterial
  , withKindTlsMaterial
  )
import Prodbox.Control.KindKubeconfigYaml (decodeBoundedYamlValue)
import Prodbox.Control.KindVolumeReadback
  ( KindVolumeBracketObservation
  , KindVolumeReadError (..)
  , observeKindVolumeBinding
  )
import System.Timeout (timeout)

data KindKubernetesReaderError
  = KindKubernetesTlsMaterial !KindTlsMaterialError
  | KindKubernetesManagerUnavailable
  | KindKubernetesDeadlineExceeded
  deriving (Eq, Show)

-- No Show instance: the manager owns client authentication material.
data KindKubernetesReader = KindKubernetesReader !Manager !String !DeploymentScope

-- | Observe only the selected volume using the configured CA and client
-- credential. The CA is not independently authenticated by this function;
-- success does not identify an owned cluster or authorize effects.
observeKindKubernetesVolumeBinding
  :: KindKubeconfig -> KindVolume -> IO (Either KindKubernetesReaderError KindVolumeBracketObservation)
observeKindKubernetesVolumeBinding config volume = do
  result <- timeout 10000000 $
    withKindKubernetesReader config $ \reader ->
      observeKindVolumeBinding
        volume
        (readKindPersistentVolume reader volume)
        (readKindPersistentVolumeClaim reader volume)
  pure (maybe (Left KindKubernetesDeadlineExceeded) id result)

withKindKubernetesReader
  :: KindKubeconfig
  -> (KindKubernetesReader -> IO value)
  -> IO (Either KindKubernetesReaderError value)
withKindKubernetesReader config action = do
  material <- parseKindTlsMaterial config
  case material of
    Left failure -> pure (Left (KindKubernetesTlsMaterial failure))
    Right parsed -> withKindTlsMaterial parsed $ \store credential -> do
      let base = defaultParamsClient "127.0.0.1" ""
          shared = (clientShared base) {sharedCAStore = store}
          hooks =
            (clientHooks base)
              { onCertificateRequest = \_ -> pure (Just credential)
              , onServerCertificate =
                  validate
                    HashSHA256
                    (defaultHooks {hookValidateName = validateLoopbackName})
                    (defaultChecks {checkLeafKeyPurpose = [KeyUsagePurpose_ServerAuth]})
              }
          debug = (clientDebug base) {debugKeyLogger = const (pure ()), debugTraceKey = const (pure ())}
          params = base {clientShared = shared, clientHooks = hooks, clientDebug = debug}
          settings =
            managerSetProxy noProxy $
              managerSetMaxHeaderLength 16384 $
                managerSetMaxNumberHeaders 64 $
                  (mkManagerSettings (TLSSettings params) Nothing)
                    { managerConnCount = 1
                    , managerIdleConnectionCount = 0
                    }
      opened <- try (newManager settings)
      case opened of
        Left (_ :: IOException) -> pure (Left KindKubernetesManagerUnavailable)
        Right manager ->
          Right
            <$> action (KindKubernetesReader manager (kindKubeconfigServer config) (kindKubeconfigScope config))

readKindPersistentVolume
  :: KindKubernetesReader -> KindVolume -> IO (Either KindVolumeReadError Value)
readKindPersistentVolume reader volume =
  readObject reader volume ("/api/v1/persistentvolumes/" ++ kindVolumeName volume)

readKindPersistentVolumeClaim
  :: KindKubernetesReader -> KindVolume -> IO (Either KindVolumeReadError Value)
readKindPersistentVolumeClaim reader volume =
  readObject
    reader
    volume
    ( "/api/v1/namespaces/"
        ++ kindVolumeNamespace volume
        ++ "/persistentvolumeclaims/"
        ++ kindVolumeName volume
    )

readObject :: KindKubernetesReader -> KindVolume -> String -> IO (Either KindVolumeReadError Value)
readObject (KindKubernetesReader manager server scope) volume path
  | scope /= kindVolumeScope volume = pure (Left KindVolumeReadDenied)
  | otherwise = do
      bounded <- timeout 5000000 $ do
        attempted <- try $ try $ do
          base <- parseRequest (server ++ path)
          let request =
                base
                  { method = "GET"
                  , requestHeaders = [("Accept", "application/json")]
                  , redirectCount = 0
                  , proxy = Nothing
                  , responseTimeout = responseTimeoutMicro 3000000
                  , checkResponse = \_ _ -> pure ()
                  }
          withResponse request manager $ \response -> do
            bytes <- readBody (responseBody response) [] 0
            pure (statusCode (responseStatus response), bytes)
        pure $ case attempted of
          Left (_ :: IOException) -> Left KindVolumeReadUnavailable
          Right (Left (_ :: HttpException)) -> Left KindVolumeReadUnavailable
          Right (Right (200, Just bytes)) -> Right bytes
          Right (Right (401, _)) -> Left KindVolumeReadDenied
          Right (Right (403, _)) -> Left KindVolumeReadDenied
          Right (Right (404, _)) -> Left KindVolumeReadNotFound
          Right (Right (200, Nothing)) -> Left KindVolumeReadInvalid
          Right _ -> Left KindVolumeReadUnavailable
      case bounded of
        Nothing -> pure (Left KindVolumeReadUnavailable)
        Just (Left failure) -> pure (Left failure)
        Just (Right bytes) -> do
          decoded <- decodeBoundedYamlValue bytes
          pure $ case (eitherDecodeStrict' bytes, decoded) of
            (Right json, Right checked) | json == checked -> Right json
            _ -> Left KindVolumeReadInvalid

readBody :: BodyReader -> [ByteString.ByteString] -> Int -> IO (Maybe ByteString.ByteString)
readBody reader chunks count = do
  chunk <- brRead reader
  if ByteString.null chunk
    then pure (Just (ByteString.concat (reverse chunks)))
    else
      if ByteString.length chunk > 262144 - count
        then pure Nothing
        else readBody reader (chunk : chunks) (count + ByteString.length chunk)

-- The selected endpoint is fixed to IPv4 loopback. Require that exact IP SAN;
-- do not fall back to a common name or skip the library's chain checks.
validateLoopbackName :: String -> Certificate -> [FailedReason]
validateLoopbackName hostname certificate
  | hostname /= "127.0.0.1" = [NameMismatch hostname]
  | otherwise = case extensionGet (certExtensions certificate) of
      Just (ExtSubjectAltName names)
        | AltNameIP (ByteString.pack [127, 0, 0, 1]) `elem` names -> []
      _ -> [NameMismatch hostname]
