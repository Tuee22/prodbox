{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Gateway
  ( renderGatewayConfigTemplate
  , renderGatewayStartPlan
  , renderGatewayStatusReport
  , resolveGatewayConfigPath
  , resolveGatewayLogLevel
  , resolveGatewayPortOverride
  , runGatewayCommand
  )
where

import Control.Applicative ((<|>))
import Control.Exception (IOException, try)
import Data.Aeson
  ( Value (..)
  , object
  , (.=)
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
import Prodbox.CLI.Command
  ( DaemonLaunchOptions (..)
  , DaemonStatusOptions (..)
  , GatewayCommand (..)
  , Plan
  , buildPlan
  , runPlanWithOptions
  )
import Prodbox.CLI.Output
  ( writeError
  , writeOutput
  )
import Prodbox.EffectDAG (fromRootIds)
import Prodbox.EffectInterpreter
  ( InterpreterContext (..)
  , runEffectDAG
  )
import Prodbox.Error (fatalError)
import Prodbox.Gateway.Client qualified as GatewayClient
import Prodbox.Gateway.Daemon qualified as Daemon
import Prodbox.Gateway.Types
  ( DaemonConfig (..)
  , Orders (..)
  , PeerEndpoint (..)
  , parseDaemonConfig
  , parseOrders
  , supportedDaemonConfigSchemaVersion
  , validateDaemonTimingAgainstOrders
  )
import Prodbox.Prerequisite (prerequisiteRegistry)
import Prodbox.Result (Result (..))
import Prodbox.Settings
  ( Credentials (..)
  , DomainSection (..)
  , Route53Section (..)
  , ValidatedSettings (..)
  , aws
  , domain
  , route53
  , validateAndLoadSettings
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, takeDirectory, (</>))
import Text.Read (readMaybe)

runGatewayCommand :: FilePath -> GatewayCommand -> IO ExitCode
runGatewayCommand repoRoot command =
  case command of
    GatewayDaemonCommand options -> runGatewayStart repoRoot options
    GatewayStatusCommand options -> runGatewayStatus options
    GatewayConfigGen outputPath nodeId -> runGatewayConfigGen repoRoot outputPath nodeId

runGatewayStart :: FilePath -> DaemonLaunchOptions -> IO ExitCode
runGatewayStart repoRoot options = do
  configPathResult <- resolveGatewayConfigPath (daemonConfigPath options)
  case configPathResult of
    Left err -> failWith err
    Right configPath -> do
      portResult <- resolveGatewayPortOverride (daemonPort options)
      case portResult of
        Left err -> failWith err
        Right portOverride -> do
          logLevel <- resolveGatewayLogLevel (daemonLogLevel options)
          configResult <- loadDaemonConfig configPath
          case configResult of
            Left err -> failWith err
            Right config -> do
              let resolvedConfig = resolveDaemonInputPaths configPath config
                  plan =
                    buildGatewayStartExecutionPlan
                      configPath
                      logLevel
                      portOverride
                      (daemonForeground options)
                      resolvedConfig
              runPlanWithOptions
                (daemonPlanOptions options)
                plan
                (applyGatewayStartPlan repoRoot configPath portOverride logLevel)

runGatewayStatus :: DaemonStatusOptions -> IO ExitCode
runGatewayStatus options = do
  configPathResult <- resolveGatewayConfigPath (daemonStatusConfigPath options)
  case configPathResult of
    Left err -> failWith err
    Right configPath -> do
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
                              writeOutput report
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

renderGatewayStartPlan :: FilePath -> String -> Maybe Int -> Bool -> DaemonConfig -> String
renderGatewayStartPlan configPath logLevel portOverride foreground config =
  unlines
    [ "GATEWAY_START_PLAN"
    , "CONFIG_PATH=" ++ configPath
    , "NODE_ID=" ++ daemonNodeId config
    , "LOG_LEVEL=" ++ logLevel
    , "PORT_OVERRIDE=" ++ maybe "<config-default>" show portOverride
    , "FOREGROUND=" ++ boolText foreground
    ]

resolveGatewayConfigPath :: Maybe FilePath -> IO (Either String FilePath)
resolveGatewayConfigPath maybeCliPath = do
  maybeEnvPath <- lookupEnv "PRODBOX_CONFIG_PATH"
  pure $
    case maybeCliPath <|> maybeEnvPath of
      Just configPath -> Right configPath
      Nothing ->
        Left
          "Missing gateway config path. Pass `--config <path>` or set `PRODBOX_CONFIG_PATH`."

resolveGatewayLogLevel :: Maybe String -> IO String
resolveGatewayLogLevel maybeCliLevel = do
  maybeEnvLevel <- lookupEnv "PRODBOX_LOG_LEVEL"
  pure (fromMaybe "info" (maybeCliLevel <|> maybeEnvLevel))

resolveGatewayPortOverride :: Maybe Int -> IO (Either String (Maybe Int))
resolveGatewayPortOverride maybeCliPort = do
  maybeEnvPort <- lookupEnv "PRODBOX_PORT"
  pure $
    case maybeCliPort of
      Just portOverride -> Right (Just portOverride)
      Nothing ->
        case maybeEnvPort of
          Nothing -> Right Nothing
          Just portText ->
            case readMaybe portText of
              Just parsedPort -> Right (Just parsedPort)
              Nothing -> Left ("Invalid PRODBOX_PORT value: " ++ portText)

buildGatewayStartExecutionPlan
  :: FilePath
  -> String
  -> Maybe Int
  -> Bool
  -> DaemonConfig
  -> Plan DaemonConfig
buildGatewayStartExecutionPlan configPath logLevel portOverride foreground =
  buildPlan
    (renderGatewayStartPlan configPath logLevel portOverride foreground)

applyGatewayStartPlan :: FilePath -> FilePath -> Maybe Int -> String -> DaemonConfig -> IO ExitCode
applyGatewayStartPlan repoRoot configPath portOverride logLevel config = do
  prerequisiteResult <- runGatewayDaemonAcquirePrerequisites repoRoot
  case prerequisiteResult of
    Failure err -> failWith err
    Success () -> Daemon.runGatewayDaemon (Just configPath) portOverride logLevel config

runGatewayDaemonAcquirePrerequisites :: FilePath -> IO (Result ())
runGatewayDaemonAcquirePrerequisites repoRoot =
  case fromRootIds ["gateway_daemon_acquire"] prerequisiteRegistry of
    Left err -> pure (Failure err)
    Right dag -> runEffectDAG (InterpreterContext repoRoot) dag

renderGatewayConfigTemplate :: ValidatedSettings -> String -> String
renderGatewayConfigTemplate settings nodeId =
  BL8.unpack (Pretty.encodePretty' prettyJsonConfig template) ++ "\n"
 where
  config = validatedConfig settings
  template =
    object
      [ "schemaVersion" .= supportedDaemonConfigSchemaVersion
      , "boot"
          .= object
            [ "node_id" .= nodeId
            , "cert_file" .= ("/path/to/" ++ nodeId ++ ".crt")
            , "key_file" .= ("/path/to/" ++ nodeId ++ ".key")
            , "ca_file" .= ("/path/to/ca.crt" :: String)
            , "orders_file" .= ("/path/to/orders.json" :: String)
            , "event_keys"
                .= Object
                  (KeyMap.singleton (Key.fromString nodeId) (String "REPLACE_WITH_SECRET_KEY"))
            , "dns_write_gate"
                .= object
                  [ "zone_id" .= Text.unpack (zone_id (route53 config))
                  , "fqdn" .= preferredGatewayFqdn settings
                  , "ttl" .= (fromIntegral (demo_ttl (domain config)) :: Integer)
                  , "aws_region" .= Text.unpack (region (aws config))
                  ]
            ]
      , "live"
          .= object
            [ "log_level" .= ("info" :: String)
            , "heartbeat_interval_seconds" .= (1.0 :: Double)
            , "reconnect_interval_seconds" .= (1.0 :: Double)
            , "sync_interval_seconds" .= (5.0 :: Double)
            , "max_clock_skew_seconds" .= (10.0 :: Double)
            , "drain_deadline_seconds" .= (30 :: Int)
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
queryGatewayState _configPath endpoint = do
  result <- GatewayClient.queryState endpoint
  pure $ case result of
    Left err -> Left ("gateway state query failed: " ++ GatewayClient.renderGatewayError err)
    Right value -> Right value

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

resolveDaemonInputPaths :: FilePath -> DaemonConfig -> DaemonConfig
resolveDaemonInputPaths configPath config =
  let baseDir = takeDirectory configPath
   in config
        { daemonCertFile = resolveRelativePath baseDir (daemonCertFile config)
        , daemonKeyFile = resolveRelativePath baseDir (daemonKeyFile config)
        , daemonCaFile = resolveRelativePath baseDir (daemonCaFile config)
        , daemonOrdersFile = resolveRelativePath baseDir (daemonOrdersFile config)
        }

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
      | (nodeId, value) <-
          sortOn fst [(Key.toString key, rawValue) | (key, rawValue) <- KeyMap.toList heartbeatObj]
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
  Text.unpack (demo_fqdn (domain config))
 where
  config = validatedConfig settings

prettyJsonConfig :: Pretty.Config
prettyJsonConfig = Pretty.defConfig {Pretty.confIndent = Pretty.Spaces 2}

boolText :: Bool -> String
boolText True = "true"
boolText False = "false"

fallback :: String -> Maybe String -> String
fallback defaultValue maybeValue = fromMaybe defaultValue maybeValue

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft transform value =
  case value of
    Left err -> Left (transform err)
    Right successValue -> Right successValue

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)
