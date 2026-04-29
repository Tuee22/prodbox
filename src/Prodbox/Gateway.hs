{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Gateway (
    renderGatewayConfigTemplate,
    renderGatewayStatusReport,
    runGatewayCommand,
)
where

import Control.Exception (IOException, try)
import Data.Aeson (
    Value (..),
    eitherDecode,
    object,
    (.=),
 )
import Data.Aeson.Encode.Pretty qualified as Pretty
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (toUpper)
import Data.List (intercalate, sortOn)
import Data.Maybe (fromMaybe)
import Data.Scientific (Scientific, floatingOrInteger)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Prodbox.CLI.Command (GatewayCommand (..))
import Prodbox.Gateway.Daemon qualified as Daemon
import Prodbox.Gateway.Types (
    DaemonConfig (..),
    Orders (..),
    PeerEndpoint (..),
    parseDaemonConfig,
    parseOrders,
    peerRestUrl,
    validateDaemonTimingAgainstOrders,
 )
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

runGatewayCommand :: FilePath -> GatewayCommand -> IO ExitCode
runGatewayCommand repoRoot command =
    case command of
        GatewayStart configPath -> runGatewayStart repoRoot configPath
        GatewayStatus configPath -> runGatewayStatus configPath
        GatewayConfigGen outputPath nodeId -> runGatewayConfigGen repoRoot outputPath nodeId

runGatewayStart :: FilePath -> FilePath -> IO ExitCode
runGatewayStart _repoRoot configPath = do
    configResult <- loadDaemonConfig configPath
    case configResult of
        Left err -> failWith err
        Right config -> Daemon.runGatewayDaemon config

runGatewayStatus :: FilePath -> IO ExitCode
runGatewayStatus configPath = do
    configResult <- loadDaemonConfig configPath
    case configResult of
        Left err -> failWith err
        Right config -> do
            let configDirectory = takeDirectory configPath
                ordersPath = resolveRelativePath configDirectory (daemonOrdersFile config)
            ordersResult <- loadOrdersFile ordersPath
            case ordersResult of
                Left err -> failWith err
                Right orders ->
                    case validateDaemonTimingAgainstOrders config orders of
                        Left err -> failWith err
                        Right () ->
                            case lookupPeerEndpoint (daemonNodeId config) orders of
                                Nothing -> failWith ("Node " ++ daemonNodeId config ++ " not in orders")
                                Just endpoint -> do
                                    stateResult <- queryGatewayState configPath endpoint
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

queryGatewayState :: FilePath -> PeerEndpoint -> IO (Either String Value)
queryGatewayState configPath endpoint = do
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

gatewayStatusUrl :: PeerEndpoint -> String
gatewayStatusUrl endpoint =
    peerRestUrl endpoint ++ "/v1/state"

lookupPeerEndpoint :: String -> Orders -> Maybe PeerEndpoint
lookupPeerEndpoint nodeId orders =
    case filter ((== nodeId) . peerNodeId) (ordersNodes orders) of
        [] -> Nothing
        endpoint : _ -> Just endpoint

loadDaemonConfig :: FilePath -> IO (Either String DaemonConfig)
loadDaemonConfig path = do
    fileResult <- readTextFile "gateway daemon config" path
    pure $ do
        contents <- fileResult
        mapLeft id (parseDaemonConfig contents)

loadOrdersFile :: FilePath -> IO (Either String Orders)
loadOrdersFile path = do
    fileResult <- readTextFile "gateway orders" path
    pure $ do
        contents <- fileResult
        mapLeft id (parseOrders contents)

readTextFile :: String -> FilePath -> IO (Either String String)
readTextFile label path = do
    result <- try (readFile path) :: IO (Either IOException String)
    pure $ mapLeft (showReadFailure label path) result

writeTextFile :: FilePath -> String -> IO (Either String ())
writeTextFile path contents = do
    result <- try (writeFile path contents) :: IO (Either IOException ())
    pure $ mapLeft (showWriteFailure path) result

showReadFailure :: String -> FilePath -> IOException -> String
showReadFailure label path err = "failed to read " ++ label ++ " " ++ path ++ ": " ++ show err

showWriteFailure :: FilePath -> IOException -> String
showWriteFailure path err = "failed to write " ++ path ++ ": " ++ show err

resolveRelativePath :: FilePath -> FilePath -> FilePath
resolveRelativePath baseDir path =
    if isAbsolute path
        then path
        else baseDir </> path

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
