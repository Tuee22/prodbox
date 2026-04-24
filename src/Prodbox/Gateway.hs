{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Gateway (
    renderGatewayConfigTemplate,
    renderGatewayStatusReport,
    runGatewayCommand,
)
where

import Control.Exception (IOException, try)
import Data.Aeson (
    FromJSON (parseJSON),
    Value (..),
    eitherDecode,
    object,
    withObject,
    (.:),
    (.:?),
    (.=),
 )
import Data.Aeson.Encode.Pretty qualified as Pretty
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (toUpper)
import Data.Foldable (for_)
import Data.List (intercalate, sortOn)
import Data.Maybe (fromMaybe)
import Data.Scientific (Scientific, floatingOrInteger)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Prodbox.CLI.Command (GatewayCommand (..))
import Prodbox.Gateway.Daemon qualified as Daemon
import Prodbox.Gateway.Types (parseDaemonConfig)
import Prodbox.Result (Result (..))
import Prodbox.Settings (
    Credentials (..),
    DomainSection (..),
    Route53Section (..),
    ValidatedSettings (..),
    aws,
    domain,
    route53,
    validateAndLoadSettings,
 )
import Prodbox.Subprocess (
    CommandSpec (..),
    ProcessOutput (..),
    captureCommand,
 )
import System.Directory (findExecutable)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)

data GatewayDaemonConfig = GatewayDaemonConfig
    { gatewayNodeId :: String
    , gatewayCertFile :: FilePath
    , gatewayKeyFile :: FilePath
    , gatewayCaFile :: FilePath
    , gatewayOrdersFile :: FilePath
    }
    deriving (Eq, Show)

data Orders = Orders
    { orderNodes :: [GatewayPeerEndpoint]
    }
    deriving (Eq, Show)

data GatewayPeerEndpoint = GatewayPeerEndpoint
    { peerNodeId :: String
    , peerStableDnsName :: String
    , peerRestHost :: String
    , peerRestPort :: Int
    }
    deriving (Eq, Show)

instance FromJSON GatewayDaemonConfig where
    parseJSON = withObject "gateway daemon config" $ \obj -> do
        nodeId <- obj .: "node_id"
        certFile <- obj .: "cert_file"
        keyFile <- obj .: "key_file"
        caFile <- obj .: "ca_file"
        ordersFile <- obj .: "orders_file"
        eventKeys <- obj .: "event_keys"
        requireJsonObject "event_keys" eventKeys
        _ <- obj .:? "heartbeat_interval_seconds" :: Parser (Maybe Scientific)
        _ <- obj .:? "reconnect_interval_seconds" :: Parser (Maybe Scientific)
        _ <- obj .:? "sync_interval_seconds" :: Parser (Maybe Scientific)
        maybeGate <- obj .:? "dns_write_gate" :: Parser (Maybe Value)
        for_ maybeGate (requireJsonObject "dns_write_gate")
        pure
            GatewayDaemonConfig
                { gatewayNodeId = nodeId
                , gatewayCertFile = certFile
                , gatewayKeyFile = keyFile
                , gatewayCaFile = caFile
                , gatewayOrdersFile = ordersFile
                }

instance FromJSON Orders where
    parseJSON = withObject "orders" $ \obj -> do
        _ <- obj .: "version_utc" :: Parser Int
        ruleValue <- obj .: "gateway_rule"
        requireJsonObject "gateway_rule" ruleValue
        nodes <- obj .: "nodes"
        pure Orders{orderNodes = nodes}

instance FromJSON GatewayPeerEndpoint where
    parseJSON = withObject "orders.nodes[]" $ \obj -> do
        nodeId <- obj .: "node_id"
        stableDnsName <- obj .: "stable_dns_name"
        restHost <- obj .: "rest_host"
        restPort <- obj .: "rest_port"
        _ <- obj .: "socket_host" :: Parser String
        _ <- obj .: "socket_port" :: Parser Int
        pure
            GatewayPeerEndpoint
                { peerNodeId = nodeId
                , peerStableDnsName = stableDnsName
                , peerRestHost = restHost
                , peerRestPort = restPort
                }

runGatewayCommand :: FilePath -> GatewayCommand -> IO ExitCode
runGatewayCommand repoRoot command =
    case command of
        GatewayStart configPath -> runGatewayStart repoRoot configPath
        GatewayStatus configPath -> runGatewayStatus configPath
        GatewayConfigGen outputPath nodeId -> runGatewayConfigGen repoRoot outputPath nodeId

runGatewayStart :: FilePath -> FilePath -> IO ExitCode
runGatewayStart _repoRoot configPath = do
    readResult <- try (readFile configPath) :: IO (Either IOException String)
    case readResult of
        Left err -> failWith ("failed to read gateway daemon config: " ++ show err)
        Right configText ->
            case parseDaemonConfig configText of
                Left err -> failWith err
                Right config -> Daemon.runGatewayDaemon config

runGatewayStatus :: FilePath -> IO ExitCode
runGatewayStatus configPath = do
    configResult <- loadJsonFile configPath parseJSON "gateway daemon config"
    case configResult of
        Left err -> failWith err
        Right config -> do
            let configDirectory = takeDirectory configPath
                ordersPath = resolveRelativePath configDirectory (gatewayOrdersFile config)
            ordersResult <- loadJsonFile ordersPath parseJSON "gateway orders"
            case ordersResult of
                Left err -> failWith err
                Right orders ->
                    case lookupPeerEndpoint (gatewayNodeId config) orders of
                        Nothing -> failWith ("Node " ++ gatewayNodeId config ++ " not in orders")
                        Just endpoint -> do
                            stateResult <- queryGatewayState configPath config endpoint
                            case stateResult of
                                Left err -> failWith err
                                Right gatewayState ->
                                    case renderGatewayStatusReport gatewayState of
                                        Left err -> failWith err
                                        Right report -> do
                                            putStr report
                                            pure ExitSuccess

runGatewayConfigGen :: FilePath -> FilePath -> String -> IO ExitCode
runGatewayConfigGen repoRoot outputPath nodeId = do
    settingsResult <- validateAndLoadSettings repoRoot
    case settingsResult of
        Left err -> failWith err
        Right settings -> do
            writeResult <- writeTextFile outputPath (renderGatewayConfigTemplate settings nodeId)
            case writeResult of
                Left err -> failWith err
                Right () -> pure ExitSuccess

renderGatewayConfigTemplate :: ValidatedSettings -> String -> String
renderGatewayConfigTemplate settings nodeId =
    BL8.unpack (Pretty.encodePretty' prettyJsonConfig template) ++ "\n"
  where
    config = validatedConfig settings
    template =
        object
            [ "node_id" .= nodeId
            , "cert_file" .= ("/path/to/" ++ nodeId ++ ".crt")
            , "key_file" .= ("/path/to/" ++ nodeId ++ ".key")
            , "ca_file" .= ("/path/to/ca.crt" :: String)
            , "orders_file" .= ("/path/to/orders.json" :: String)
            , "event_keys"
                .= Object
                    (KeyMap.singleton (Key.fromString nodeId) (String "REPLACE_WITH_SECRET_KEY"))
            , "heartbeat_interval_seconds" .= (1.0 :: Double)
            , "reconnect_interval_seconds" .= (1.0 :: Double)
            , "sync_interval_seconds" .= (5.0 :: Double)
            , "dns_write_gate"
                .= object
                    [ "zone_id" .= Text.unpack (zone_id (route53 config))
                    , "fqdn" .= preferredGatewayFqdn settings
                    , "ttl" .= (fromIntegral (demo_ttl (domain config)) :: Integer)
                    , "aws_region" .= Text.unpack (region (aws config))
                    ]
            ]

renderGatewayStatusReport :: Value -> Either String String
renderGatewayStatusReport payload =
    case payload of
        Object obj ->
            Right
                ( unlines
                    ( [ "Gateway status"
                      , "NODE_ID=" ++ fromMaybe "<unknown>" (lookupTextField "node_id" obj)
                      , "GATEWAY_OWNER=" ++ fromMaybe "<unknown>" (lookupTextField "gateway_owner" obj)
                      , "ACTIVE_CLAIM=" ++ boolText (lookupBoolField "has_active_claim" obj)
                      , "MESH_PEERS=" ++ renderMeshPeers obj
                      , "EVENT_COUNT=" ++ renderEventCount obj
                      , "LAST_PUBLIC_IP=" ++ fallback "<unknown>" (lookupTextField "last_public_ip_observed" obj)
                      , "LAST_DNS_WRITE_IP=" ++ fallback "<none>" (lookupTextField "last_dns_write_ip" obj)
                      , "LAST_DNS_WRITE_AT=" ++ fallback "<none>" (lookupTextField "last_dns_write_at_utc" obj)
                      , "DNS_WRITE_GATE=" ++ renderDnsWriteGate obj
                      ]
                        ++ renderHeartbeatLines obj
                    )
                )
        _ -> Left "gateway state response was not a JSON object"

queryGatewayState :: FilePath -> GatewayDaemonConfig -> GatewayPeerEndpoint -> IO (Either String Value)
queryGatewayState configPath config endpoint = do
    curlExists <- findExecutable "curl"
    case curlExists of
        Nothing -> pure (Left "`gateway status` requires `curl` to query the daemon REST API.")
        Just _ -> do
            outputResult <-
                captureCommand
                    CommandSpec
                        { commandPath = "curl"
                        , commandArguments =
                            [ "-fsSL"
                            , "--max-time"
                            , "5"
                            , "--cert"
                            , gatewayCertFile config
                            , "--key"
                            , gatewayKeyFile config
                            , "--cacert"
                            , gatewayCaFile config
                            , gatewayStatusUrl endpoint
                            ]
                        , commandEnvironment = Nothing
                        , commandWorkingDirectory = Just (takeDirectory configPath)
                        }
            pure $
                case outputResult of
                    Failure err -> Left ("failed to start gateway status curl request: " ++ err)
                    Success output ->
                        case processExitCode output of
                            ExitSuccess ->
                                case eitherDecode (BL8.pack (processStdout output)) of
                                    Left err -> Left ("gateway state response was not valid JSON: " ++ err)
                                    Right value -> Right value
                            ExitFailure _ -> Left ("gateway state query failed: " ++ outputDetail output)

gatewayStatusUrl :: GatewayPeerEndpoint -> String
gatewayStatusUrl endpoint =
    "https://"
        ++ restDialHost endpoint
        ++ ":"
        ++ show (peerRestPort endpoint)
        ++ "/v1/state"

restDialHost :: GatewayPeerEndpoint -> String
restDialHost endpoint =
    case peerRestHost endpoint of
        "0.0.0.0" -> peerStableDnsName endpoint
        "::" -> peerStableDnsName endpoint
        value -> value

lookupPeerEndpoint :: String -> Orders -> Maybe GatewayPeerEndpoint
lookupPeerEndpoint nodeId orders =
    case filter ((== nodeId) . peerNodeId) (orderNodes orders) of
        [] -> Nothing
        endpoint : _ -> Just endpoint

loadJsonFile :: (FromJSON a) => FilePath -> (Value -> Parser a) -> String -> IO (Either String a)
loadJsonFile path parser label = do
    fileResult <- readBinaryFile path
    pure $ do
        contents <- fileResult
        payload <- mapLeft (("invalid " ++ label ++ " JSON: ") ++) (eitherDecode contents :: Either String Value)
        mapLeft (("invalid " ++ label ++ ": ") ++) (parseEither parser payload)

readBinaryFile :: FilePath -> IO (Either String BL.ByteString)
readBinaryFile path = do
    result <- try (BL.readFile path) :: IO (Either IOException BL.ByteString)
    pure $ mapLeft (showReadFailure path) result

writeTextFile :: FilePath -> String -> IO (Either String ())
writeTextFile path contents = do
    result <- try (writeFile path contents) :: IO (Either IOException ())
    pure $ mapLeft (showWriteFailure path) result

showReadFailure :: FilePath -> IOException -> String
showReadFailure path err = "failed to read " ++ path ++ ": " ++ show err

showWriteFailure :: FilePath -> IOException -> String
showWriteFailure path err = "failed to write " ++ path ++ ": " ++ show err

resolveRelativePath :: FilePath -> FilePath -> FilePath
resolveRelativePath baseDir path =
    if isAbsolute path
        then path
        else baseDir </> path

requireJsonObject :: String -> Value -> Parser ()
requireJsonObject fieldName value =
    case value of
        Object _ -> pure ()
        _ -> fail (fieldName ++ " must be a JSON object")

lookupTextField :: String -> KeyMap.KeyMap Value -> Maybe String
lookupTextField fieldName obj =
    case KeyMap.lookup (Key.fromString fieldName) obj of
        Just (String value) -> Just (Text.unpack value)
        _ -> Nothing

lookupBoolField :: String -> KeyMap.KeyMap Value -> Bool
lookupBoolField fieldName obj =
    case KeyMap.lookup (Key.fromString fieldName) obj of
        Just (Bool value) -> value
        _ -> False

lookupObjectField :: String -> KeyMap.KeyMap Value -> Maybe (KeyMap.KeyMap Value)
lookupObjectField fieldName obj =
    case KeyMap.lookup (Key.fromString fieldName) obj of
        Just (Object value) -> Just value
        _ -> Nothing

lookupArrayField :: String -> KeyMap.KeyMap Value -> [Value]
lookupArrayField fieldName obj =
    case KeyMap.lookup (Key.fromString fieldName) obj of
        Just (Array values) -> Vector.toList values
        _ -> []

renderMeshPeers :: KeyMap.KeyMap Value -> String
renderMeshPeers obj =
    case [Text.unpack value | String value <- lookupArrayField "mesh_peers" obj] of
        [] -> "<none>"
        peers -> intercalate "," peers

renderEventCount :: KeyMap.KeyMap Value -> String
renderEventCount obj =
    case KeyMap.lookup (Key.fromString "event_count") obj of
        Just (Number value) -> renderIntegralText value
        Just (String value) -> Text.unpack value
        _ -> "0"

renderDnsWriteGate :: KeyMap.KeyMap Value -> String
renderDnsWriteGate obj =
    case lookupObjectField "dns_write_gate" obj of
        Nothing -> "<disabled>"
        Just gate ->
            fallback "<unknown>" (lookupTextField "fqdn" gate)
                ++ "@"
                ++ fallback "<unknown>" (lookupTextField "zone_id" gate)
                ++ " ttl="
                ++ renderTtl gate

renderTtl :: KeyMap.KeyMap Value -> String
renderTtl gate =
    case KeyMap.lookup (Key.fromString "ttl") gate of
        Just (Number value) -> renderIntegralText value
        Just (String value) -> Text.unpack value
        _ -> "<unknown>"

renderHeartbeatLines :: KeyMap.KeyMap Value -> [String]
renderHeartbeatLines obj =
    case lookupObjectField "heartbeat_age_seconds" obj of
        Nothing -> []
        Just heartbeatObj ->
            [ "HEARTBEAT_" ++ normalizeNodeId nodeId ++ "=" ++ renderHeartbeatValue value
            | (nodeId, value) <- sortOn fst [(Key.toString key, rawValue) | (key, rawValue) <- KeyMap.toList heartbeatObj]
            ]

normalizeNodeId :: String -> String
normalizeNodeId = map normalizeCharacter
  where
    normalizeCharacter '-' = '_'
    normalizeCharacter value = toUpper value

renderHeartbeatValue :: Value -> String
renderHeartbeatValue value =
    case value of
        Number numericValue -> show numericValue
        String textValue -> Text.unpack textValue
        Bool boolValue -> boolText boolValue
        Null -> "null"
        _ -> "<unknown>"

renderIntegralText :: Scientific -> String
renderIntegralText value =
    case floatingOrInteger value :: Either Double Integer of
        Left floatingValue -> show floatingValue
        Right integerValue -> show integerValue

preferredGatewayFqdn :: ValidatedSettings -> String
preferredGatewayFqdn settings =
    case vscode_fqdn (domain config) of
        Just value -> Text.unpack value
        Nothing -> Text.unpack (demo_fqdn (domain config))
  where
    config = validatedConfig settings

prettyJsonConfig :: Pretty.Config
prettyJsonConfig = Pretty.defConfig{Pretty.confIndent = Pretty.Spaces 2}

boolText :: Bool -> String
boolText True = "true"
boolText False = "false"

fallback :: String -> Maybe String -> String
fallback defaultValue maybeValue = fromMaybe defaultValue maybeValue

outputDetail :: ProcessOutput -> String
outputDetail output =
    case (trim (processStderr output), trim (processStdout output)) of
        (stderrText, _) | stderrText /= "" -> stderrText
        ("", stdoutText) | stdoutText /= "" -> stdoutText
        _ -> "subprocess exited without output"

trim :: String -> String
trim = f . f
  where
    f = reverse . dropWhile (`elem` [' ', '\n', '\r', '\t'])

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft transform value =
    case value of
        Left err -> Left (transform err)
        Right successValue -> Right successValue

failWith :: String -> IO ExitCode
failWith message = do
    hPutStrLn stderr message
    pure (ExitFailure 1)
