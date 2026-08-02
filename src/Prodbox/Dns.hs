{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Dns
  ( HomeGatewayDnsObservation (..)
  , changeRoute53ARecordSetInZone
  , configuredPublicHostFqdns
  , decodeHomeGatewayDnsObservation
  , fetchPublicIp
  , preferredApiHostFqdn
  , preferredIdentityHostFqdn
  , preferredPublicHostFqdn
  , preferredWebsocketHostFqdn
  , queryPublicEdgeDnsRecordValues
  , queryRoute53Record
  , queryRoute53ARecordValuesInZone
  , queryRoute53RecordInZone
  , renderDnsStatusReport
  , runDnsCommand
  )
where

import Data.Aeson
  ( Value (..)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.CLI.Command (DnsCommand (..))
import Prodbox.CLI.Output
  ( writeError
  , writeOutput
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  )
import Prodbox.ControlPlane.ProviderCaller
  ( dispatchHostProviderIntentFresh
  , renderProviderCallerError
  )
import Prodbox.Error (fatalError)
import Prodbox.Gateway.Client qualified as GatewayClient
import Prodbox.Http.Client
  ( defaultHttpConfig
  , httpGetText
  , renderHttpError
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ObservePublicARecord, ReconcilePublicARecord)
  , mkPublicARecordRef
  )
import Prodbox.PublicEdge
  ( publicFqdn
  , sharedPublicHostFqdns
  )
import Prodbox.Settings
  ( Route53Section (..)
  , ValidatedSettings (..)
  , route53
  , validateAndLoadSettings
  )
import Prodbox.Substrate (Substrate (..))
import System.Exit
  ( ExitCode (..)
  )

runDnsCommand :: FilePath -> DnsCommand -> IO ExitCode
runDnsCommand repoRoot command =
  case command of
    DnsCheck -> do
      settingsResult <- validateAndLoadSettings repoRoot
      case settingsResult of
        Left err -> failWith err
        Right settings -> do
          publicIpResult <- fetchPublicIp
          case publicIpResult of
            Left err -> failWith err
            Right publicIp -> do
              recordResult <- queryRoute53Record repoRoot settings (publicFqdn settings)
              case recordResult of
                Left err -> failWith err
                Right currentRecordIp -> do
                  writeOutput (renderDnsStatusReport settings publicIp currentRecordIp)
                  pure ExitSuccess

renderDnsStatusReport :: ValidatedSettings -> String -> Maybe String -> String
renderDnsStatusReport settings publicIp currentRecordIp =
  unlines
    [ "DNS status"
    , "FQDN=" ++ publicFqdn settings
    , "PUBLIC_IP=" ++ publicIp
    , "ROUTE53_A_RECORD=" ++ maybe "<missing>" id currentRecordIp
    , "STATUS=" ++ status
    ]
 where
  status
    | currentRecordIp == Just publicIp = "in-sync"
    | currentRecordIp == Nothing = "record-missing"
    | otherwise = "mismatch"

preferredPublicHostFqdn :: ValidatedSettings -> String
preferredPublicHostFqdn = publicFqdn

preferredIdentityHostFqdn :: ValidatedSettings -> String
preferredIdentityHostFqdn = publicFqdn

preferredApiHostFqdn :: ValidatedSettings -> String
preferredApiHostFqdn = publicFqdn

preferredWebsocketHostFqdn :: ValidatedSettings -> String
preferredWebsocketHostFqdn = publicFqdn

configuredPublicHostFqdns :: ValidatedSettings -> [String]
configuredPublicHostFqdns settings = nub (sharedPublicHostFqdns settings)

fetchPublicIp :: IO (Either String String)
fetchPublicIp = do
  result <- httpGetText defaultHttpConfig "https://api.ipify.org"
  pure $ case result of
    Left err -> Left ("public IP lookup failed: " ++ renderHttpError err)
    Right body -> case words body of
      (value : _) -> Right value
      [] -> Left "public IP lookup returned an empty response"

queryRoute53Record :: FilePath -> ValidatedSettings -> String -> IO (Either String (Maybe String))
queryRoute53Record _repoRoot settings fqdn = do
  valuesResult <- queryHomeGatewayDnsRecordValues settings fqdn
  pure $ case valuesResult of
    Left err -> Left err
    Right [] -> Right Nothing
    Right (firstValue : _) -> Right (Just firstValue)

-- | Observe public-edge DNS through its substrate owner. Home observation is
-- the exact, non-secret Gateway-DNS status projection. AWS observation is a
-- registered, signed Authority/Provider read and never borrows or exports the
-- LongLived home identity.
queryPublicEdgeDnsRecordValues
  :: FilePath
  -> ValidatedSettings
  -> Substrate
  -> Text
  -> String
  -> IO (Either String [String])
queryPublicEdgeDnsRecordValues repoRoot settings substrate hostedZoneId fqdn =
  case substrate of
    SubstrateHomeLocal -> queryHomeGatewayDnsRecordValues settings fqdn
    SubstrateAws ->
      queryRoute53ARecordValuesInZone repoRoot settings hostedZoneId fqdn

data HomeGatewayDnsObservation = HomeGatewayDnsObservation
  { homeGatewayDnsObservationValue :: !(Maybe String)
  , homeGatewayDnsObservationWritable :: !Bool
  }
  deriving (Eq, Show)

queryHomeGatewayDnsRecordValues
  :: ValidatedSettings -> String -> IO (Either String [String])
queryHomeGatewayDnsRecordValues settings fqdn = do
  endpoint <- GatewayClient.hostLoopbackGatewayEndpointFromEnv
  stateResult <- GatewayClient.queryState endpoint
  pure $ case stateResult of
    Left err ->
      Left
        ( "Gateway-DNS observation failed: "
            ++ GatewayClient.renderGatewayError err
        )
    Right state -> do
      observed <-
        decodeHomeGatewayDnsObservation
          (zone_id (route53 (validatedConfig settings)))
          fqdn
          state
      if homeGatewayDnsObservationWritable observed
        then Right (maybe [] pure (homeGatewayDnsObservationValue observed))
        else
          Left "Gateway-DNS observation is bound to the requested record but its write authority is not ready"

decodeHomeGatewayDnsObservation
  :: Text -> String -> Value -> Either String HomeGatewayDnsObservation
decodeHomeGatewayDnsObservation expectedZone expectedFqdn payload = do
  state <- valueObject "Gateway state" payload
  gateValue <- requiredField "dns_write_gate" state
  gate <- valueObject "Gateway DNS write gate" gateValue
  observedZone <- textField "zone_id" gate
  observedFqdn <- textField "fqdn" gate
  if observedZone == expectedZone
    then Right ()
    else Left "Gateway-DNS observation is bound to a different hosted zone"
  if canonicalFqdn observedFqdn == canonicalFqdn (Text.pack expectedFqdn)
    then Right ()
    else Left "Gateway-DNS observation is bound to a different FQDN"
  writable <- boolField "can_write_dns" state
  observedValue <- optionalTextField "last_dns_write_ip" state
  pure
    HomeGatewayDnsObservation
      { homeGatewayDnsObservationValue = Text.unpack <$> observedValue
      , homeGatewayDnsObservationWritable = writable
      }

valueObject :: String -> Value -> Either String (KeyMap.KeyMap Value)
valueObject _ (Object value) = Right value
valueObject label _ = Left (label ++ " is not a JSON object")

requiredField :: Text -> KeyMap.KeyMap Value -> Either String Value
requiredField name fields =
  case KeyMap.lookup (fromTextKey name) fields of
    Nothing -> Left ("Gateway-DNS observation is missing `" ++ Text.unpack name ++ "`")
    Just value -> Right value

textField :: Text -> KeyMap.KeyMap Value -> Either String Text
textField name fields = do
  value <- requiredField name fields
  case value of
    String text -> Right text
    _ -> Left ("Gateway-DNS observation field `" ++ Text.unpack name ++ "` is not text")

boolField :: Text -> KeyMap.KeyMap Value -> Either String Bool
boolField name fields = do
  value <- requiredField name fields
  case value of
    Bool flag -> Right flag
    _ -> Left ("Gateway-DNS observation field `" ++ Text.unpack name ++ "` is not boolean")

optionalTextField :: Text -> KeyMap.KeyMap Value -> Either String (Maybe Text)
optionalTextField name fields = do
  value <- requiredField name fields
  case value of
    Null -> Right Nothing
    String text -> Right (Just text)
    _ -> Left ("Gateway-DNS observation field `" ++ Text.unpack name ++ "` is not text or null")

fromTextKey :: Text -> Key.Key
fromTextKey = Key.fromText

canonicalFqdn :: Text -> Text
canonicalFqdn = Text.toCaseFold . Text.dropWhileEnd (== '.')

-- | Compatibility-shaped AWS observation surface backed by the typed Provider
-- read. It must never resolve a Target generation onto the host.
queryRoute53RecordInZone
  :: FilePath
  -> ValidatedSettings
  -> Text
  -> String
  -> IO (Either String (Maybe String))
queryRoute53RecordInZone repoRoot settings hostedZoneId fqdn = do
  valuesResult <- queryRoute53ARecordValuesInZone repoRoot settings hostedZoneId fqdn
  pure $ case valuesResult of
    Left err -> Left err
    Right [] -> Right Nothing
    Right (firstValue : _) -> Right (Just firstValue)

queryRoute53ARecordValuesInZone
  :: FilePath
  -> ValidatedSettings
  -> Text
  -> String
  -> IO (Either String [String])
queryRoute53ARecordValuesInZone repoRoot _settings hostedZoneId fqdn =
  case mkPublicARecordRef hostedZoneId (Text.pack fqdn) 60 ["0.0.0.0"] of
    Left err -> pure (Left ("invalid registered AWS public A-record coordinate: " ++ show err))
    Right ref -> do
      observed <-
        dispatchHostProviderIntentFresh
          LifecycleAuthorityOperator
          repoRoot
          "observe-public-a"
          (ObservePublicARecord ref)
      pure $ case observed of
        Left err -> Left (renderProviderCallerError err)
        Right evidence -> parsePublicARecordEvidence evidence

changeRoute53ARecordSetInZone
  :: FilePath
  -> ValidatedSettings
  -> Text
  -> String
  -> [String]
  -> Int
  -> IO (Either String ())
changeRoute53ARecordSetInZone repoRoot _settings hostedZoneId fqdn recordValues ttlValue
  | null recordValues = pure (Left ("refusing to write empty Route 53 A record set for " ++ fqdn))
  | ttlValue <= 0 = pure (Left ("refusing invalid Route 53 TTL for " ++ fqdn))
  | otherwise =
      case mkPublicARecordRef
        hostedZoneId
        (Text.pack fqdn)
        (fromIntegral ttlValue)
        (map Text.pack (sort recordValues)) of
        Left err -> pure (Left ("invalid registered AWS public A-record: " ++ show err))
        Right ref -> do
          reconciled <-
            dispatchHostProviderIntentFresh
              LifecycleAuthorityOperator
              repoRoot
              "reconcile-public-a"
              (ReconcilePublicARecord ref)
          pure $ case reconciled of
            Left err -> Left (renderProviderCallerError err)
            Right _ -> Right ()

parsePublicARecordEvidence :: Text -> Either String [String]
parsePublicARecordEvidence evidence =
  case Text.stripPrefix "public-a-values:" evidence of
    Nothing -> Left "Lifecycle Provider returned invalid public A-record evidence"
    Just raw
      | Text.null raw -> Right []
      | otherwise -> Right (map Text.unpack (Text.splitOn "," raw))

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)
