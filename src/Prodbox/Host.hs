{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Host
  ( LanAddressing (..)
  , PortStatus (..)
  , NtpDisposition (..)
  , detectLanAddressing
  , renderPortAvailabilityReport
  , parseTimedatectlNtpDisposition
  , renderHostInfoReport
  , runHostCommand
  )
where

import Control.Monad (filterM)
import Data.Aeson (Value (..), eitherDecode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bits (shiftL, xor, (.&.), (.|.))
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isAsciiUpper)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Numeric (readHex)
import Prodbox.CLI.Command (HostCommand (..))
import Prodbox.CLI.Output (writeError)
import Prodbox.Dns
  ( fetchPublicIp
  , queryRoute53Record
  )
import Prodbox.Effect (Effect (..))
import Prodbox.EffectDAG (fromRootIds)
import Prodbox.EffectInterpreter (InterpreterContext (..), runEffect, runEffectDAG)
import Prodbox.Error (fatalError)
import Prodbox.Prerequisite (prerequisiteRegistry)
import Prodbox.PublicEdge (publicFqdn)
import Prodbox.Result (Result (..))
import Prodbox.Settings
  ( DeploymentSection (..)
  , ValidatedSettings (..)
  , deployment
  , public_edge_advertisement_mode
  , validateAndLoadSettings
  , validatedConfig
  )
import Prodbox.Subprocess (CommandSpec (..), ProcessOutput (..), captureCommand)
import System.Directory (doesFileExist, findExecutable)
import System.Exit (ExitCode (..))

data PortStatus = PortStatus
  { portNumber :: Int
  , portAvailable :: Bool
  , portDetail :: String
  }
  deriving (Eq, Show)

-- | Disposition of the host's NTP synchronization, derived from
-- @timedatectl status@ on Ubuntu 24.04 hosts.  The supported-host gate
-- treats @NtpUnsynced@ as a fail-fast condition because every freshness
-- judgement and claim/yield ordering check in the gateway daemon compares
-- wall-clock UTC stamps across nodes.
data NtpDisposition
  = NtpSynchronized
  | NtpUnsynced String
  | NtpUnknown String
  deriving (Eq, Show)

prodboxNamespace :: String
prodboxNamespace = "prodbox"

data EdgeRuntime = EdgeRuntime
  { edgePublicIp :: String
  , edgePublicHost :: String
  , edgeRoute53RecordIp :: Maybe String
  , edgeActiveLanInterface :: String
  , edgeActiveLanIpv4 :: String
  , edgeActiveLanCidr :: String
  , edgeMetallbPool :: String
  , edgeMetallbAdvertisementMode :: String
  , edgeExpectedLbIp :: String
  , edgeEnvoyServiceIp :: String
  , edgeEnvoyGatewayDeploymentReady :: Bool
  , edgeGatewayClassAccepted :: Bool
  , edgeGatewayReady :: Bool
  , edgeAuthRouteAccepted :: Bool
  , edgeVscodeRouteAccepted :: Bool
  , edgeApiRouteAccepted :: Bool
  , edgeWebsocketRouteAccepted :: Bool
  , edgeHarborRouteAccepted :: Bool
  , edgeMinioRouteAccepted :: Bool
  , edgeVscodeSecurityPolicyAttached :: Bool
  , edgeApiSecurityPolicyAttached :: Bool
  , edgeWebsocketSecurityPolicyAttached :: Bool
  , edgeHarborSecurityPolicyAttached :: Bool
  , edgeMinioSecurityPolicyAttached :: Bool
  , edgeCertificateReady :: String
  }
  deriving (Eq, Show)

data LanAddressing = LanAddressing
  { lanInterfaceName :: String
  , lanInterfaceIpv4 :: String
  , lanNetworkCidr :: String
  , lanMetallbPool :: String
  , lanIngressLbIp :: String
  }
  deriving (Eq, Show)

runHostCommand :: FilePath -> HostCommand -> IO ExitCode
runHostCommand repoRoot command =
  case command of
    HostEnsureTools -> do
      prerequisiteResult <-
        runPrerequisites
          repoRoot
          [ "tool_kubectl"
          , "tool_helm"
          , "tool_pulumi"
          , "tool_docker"
          , "tool_ctr"
          , "tool_sudo"
          , "tool_systemctl"
          , "tool_rke2"
          ]
      case prerequisiteResult of
        Failure err -> failWith err
        Success () -> do
          putStrLn "All required host tools are available."
          pure ExitSuccess
    HostCheckPorts -> runHostCheckPorts
    HostInfo -> runHostInfo repoRoot
    HostFirewall -> runSingleEffect repoRoot "Check firewall status" (commandEffect "ufw" ["status"] repoRoot)
    HostPublicEdge -> runHostPublicEdge repoRoot

runHostPublicEdge :: FilePath -> IO ExitCode
runHostPublicEdge repoRoot = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      publicIpResult <- fetchPublicIp
      case publicIpResult of
        Left err -> failWith err
        Right publicIp -> do
          route53Result <- queryRoute53Record repoRoot settings (publicFqdn settings)
          case firstFailure [toUnit route53Result] of
            Just err -> failWith err
            Nothing -> do
              lanResult <- detectLanAddressing
              envoyGatewayDeploymentResult <-
                optionalKubectlJson
                  repoRoot
                  (Just "envoy-gateway-system")
                  ["get", "deployment", "envoy-gateway", "-o", "json", "--ignore-not-found=true"]
              gatewayClassResult <-
                optionalKubectlJson
                  repoRoot
                  Nothing
                  ["get", "gatewayclass", "prodbox-public-edge", "-o", "json", "--ignore-not-found=true"]
              envoyServiceResult <-
                optionalKubectlJson
                  repoRoot
                  (Just "envoy-gateway-system")
                  [ "get"
                  , "svc"
                  , "-l"
                  , "gateway.envoyproxy.io/owning-gateway-namespace=vscode,gateway.envoyproxy.io/owning-gateway-name=public-edge"
                  , "-o"
                  , "json"
                  ]
              gatewayResult <-
                optionalKubectlJson
                  repoRoot
                  (Just "vscode")
                  ["get", "gateway", "public-edge", "-o", "json", "--ignore-not-found=true"]
              vscodeRouteResult <-
                optionalKubectlJson
                  repoRoot
                  (Just "vscode")
                  ["get", "httproute", "vscode", "-o", "json", "--ignore-not-found=true"]
              authRouteResult <-
                optionalKubectlJson
                  repoRoot
                  (Just "vscode")
                  ["get", "httproute", "keycloak", "-o", "json", "--ignore-not-found=true"]
              apiRouteResult <-
                optionalKubectlJson
                  repoRoot
                  (Just "api")
                  ["get", "httproute", "api", "-o", "json", "--ignore-not-found=true"]
              websocketRouteResult <-
                optionalKubectlJson
                  repoRoot
                  (Just "websocket")
                  ["get", "httproute", "websocket", "-o", "json", "--ignore-not-found=true"]
              harborRouteResult <-
                optionalKubectlJson
                  repoRoot
                  (Just "harbor")
                  ["get", "httproute", "harbor-ui", "-o", "json", "--ignore-not-found=true"]
              minioRouteResult <-
                optionalKubectlJson
                  repoRoot
                  (Just prodboxNamespace)
                  ["get", "httproute", "minio-console", "-o", "json", "--ignore-not-found=true"]
              vscodeSecurityPolicyResult <-
                optionalKubectlJson
                  repoRoot
                  (Just "vscode")
                  ["get", "securitypolicy", "vscode-oidc", "-o", "json", "--ignore-not-found=true"]
              apiSecurityPolicyResult <-
                optionalKubectlJson
                  repoRoot
                  (Just "api")
                  ["get", "securitypolicy", "api-jwt", "-o", "json", "--ignore-not-found=true"]
              websocketSecurityPolicyResult <-
                optionalKubectlJson
                  repoRoot
                  (Just "websocket")
                  ["get", "securitypolicy", "websocket-jwt", "-o", "json", "--ignore-not-found=true"]
              harborSecurityPolicyResult <-
                optionalKubectlJson
                  repoRoot
                  (Just "harbor")
                  ["get", "securitypolicy", "harbor-oidc", "-o", "json", "--ignore-not-found=true"]
              minioSecurityPolicyResult <-
                optionalKubectlJson
                  repoRoot
                  (Just prodboxNamespace)
                  ["get", "securitypolicy", "minio-oidc", "-o", "json", "--ignore-not-found=true"]
              certificateResult <-
                optionalKubectlJson
                  repoRoot
                  (Just "vscode")
                  ["get", "certificate", "public-edge-tls", "-o", "json", "--ignore-not-found=true"]
              case firstFailure
                [ toUnit lanResult
                , toUnit envoyGatewayDeploymentResult
                , toUnit gatewayClassResult
                , toUnit envoyServiceResult
                , toUnit gatewayResult
                , toUnit vscodeRouteResult
                , toUnit authRouteResult
                , toUnit apiRouteResult
                , toUnit websocketRouteResult
                , toUnit harborRouteResult
                , toUnit minioRouteResult
                , toUnit vscodeSecurityPolicyResult
                , toUnit apiSecurityPolicyResult
                , toUnit websocketSecurityPolicyResult
                , toUnit harborSecurityPolicyResult
                , toUnit minioSecurityPolicyResult
                , toUnit certificateResult
                ] of
                Just err -> failWith err
                Nothing ->
                  case ( route53Result
                       , lanResult
                       , envoyGatewayDeploymentResult
                       , gatewayClassResult
                       , envoyServiceResult
                       , gatewayResult
                       , vscodeRouteResult
                       , authRouteResult
                       , apiRouteResult
                       , websocketRouteResult
                       , harborRouteResult
                       , minioRouteResult
                       , vscodeSecurityPolicyResult
                       , apiSecurityPolicyResult
                       , websocketSecurityPolicyResult
                       , harborSecurityPolicyResult
                       , minioSecurityPolicyResult
                       , certificateResult
                       ) of
                    ( Right route53RecordIp
                      , Right lan
                      , Right envoyGatewayDeploymentDoc
                      , Right gatewayClassDoc
                      , Right envoyServiceDoc
                      , Right gatewayDoc
                      , Right vscodeRouteDoc
                      , Right authRouteDoc
                      , Right apiRouteDoc
                      , Right websocketRouteDoc
                      , Right harborRouteDoc
                      , Right minioRouteDoc
                      , Right vscodeSecurityPolicyDoc
                      , Right apiSecurityPolicyDoc
                      , Right websocketSecurityPolicyDoc
                      , Right harborSecurityPolicyDoc
                      , Right minioSecurityPolicyDoc
                      , Right certificateDoc
                      ) -> do
                        let runtime =
                              EdgeRuntime
                                { edgePublicIp = publicIp
                                , edgePublicHost = publicFqdn settings
                                , edgeRoute53RecordIp = route53RecordIp
                                , edgeActiveLanInterface = lanInterfaceName lan
                                , edgeActiveLanIpv4 = lanInterfaceIpv4 lan
                                , edgeActiveLanCidr = lanNetworkCidr lan
                                , edgeMetallbPool = lanMetallbPool lan
                                , edgeMetallbAdvertisementMode = configuredMetallbAdvertisementMode settings
                                , edgeExpectedLbIp = lanIngressLbIp lan
                                , edgeEnvoyServiceIp = serviceLoadBalancerIp envoyServiceDoc
                                , edgeEnvoyGatewayDeploymentReady = deploymentReady envoyGatewayDeploymentDoc
                                , edgeGatewayClassAccepted = gatewayClassAccepted gatewayClassDoc
                                , edgeGatewayReady = gatewayReady gatewayDoc
                                , edgeAuthRouteAccepted = httpRouteAccepted authRouteDoc
                                , edgeVscodeRouteAccepted = httpRouteAccepted vscodeRouteDoc
                                , edgeApiRouteAccepted = httpRouteAccepted apiRouteDoc
                                , edgeWebsocketRouteAccepted = httpRouteAccepted websocketRouteDoc
                                , edgeHarborRouteAccepted = httpRouteAccepted harborRouteDoc
                                , edgeMinioRouteAccepted = httpRouteAccepted minioRouteDoc
                                , edgeVscodeSecurityPolicyAttached = securityPolicyAttached "vscode" vscodeSecurityPolicyDoc
                                , edgeApiSecurityPolicyAttached = securityPolicyAttached "api" apiSecurityPolicyDoc
                                , edgeWebsocketSecurityPolicyAttached = securityPolicyAttached "websocket" websocketSecurityPolicyDoc
                                , edgeHarborSecurityPolicyAttached = securityPolicyAttached "harbor-ui" harborSecurityPolicyDoc
                                , edgeMinioSecurityPolicyAttached = securityPolicyAttached "minio-console" minioSecurityPolicyDoc
                                , edgeCertificateReady = certificateReady certificateDoc
                                }
                        putStr (renderPublicEdgeReport runtime)
                        pure ExitSuccess
                    _ -> failWith "internal error: host public-edge results were incomplete"

renderPortAvailabilityReport :: [PortStatus] -> String
renderPortAvailabilityReport statuses =
  unlines (headerLine : detailLines ++ [summaryLine, statusLine])
 where
  headerLine = "Host port check"
  detailLines = map renderStatus statuses
  busyPorts = map (show . portNumber) (filter (not . portAvailable) statuses)
  summaryLine =
    case busyPorts of
      [] -> "Ports available: " ++ commaSeparated (map (show . portNumber) statuses)
      _ -> "Ports unavailable: " ++ commaSeparated busyPorts
  statusLine = "STATUS=" ++ if null busyPorts then "available" else "busy"

renderStatus :: PortStatus -> String
renderStatus status =
  "PORT="
    ++ show (portNumber status)
    ++ " AVAILABLE="
    ++ boolText (portAvailable status)
    ++ " DETAIL="
    ++ portDetail status

renderPublicEdgeReport :: EdgeRuntime -> String
renderPublicEdgeReport runtime =
  unlines
    [ "Public edge diagnostic"
    , "PUBLIC_FQDN=" ++ edgePublicHost runtime
    , "PUBLIC_IP=" ++ edgePublicIp runtime
    , "PUBLIC_ROUTE53_A_RECORD=" ++ maybe "<missing>" id (edgeRoute53RecordIp runtime)
    , "PUBLIC_ROUTE53_STATUS=" ++ publicRoute53Status
    , "ACTIVE_LAN_INTERFACE=" ++ edgeActiveLanInterface runtime
    , "ACTIVE_LAN_IPV4=" ++ edgeActiveLanIpv4 runtime
    , "ACTIVE_LAN_CIDR=" ++ edgeActiveLanCidr runtime
    , "METALLB_POOL=" ++ edgeMetallbPool runtime
    , "METALLB_ADVERTISEMENT_MODE=" ++ edgeMetallbAdvertisementMode runtime
    , "EDGE_LB_IP=" ++ edgeExpectedLbIp runtime
    , "ENVOY_SERVICE_IP=" ++ edgeEnvoyServiceIp runtime
    , "ENVOY_GATEWAY_DEPLOYMENT_READY=" ++ boolText (edgeEnvoyGatewayDeploymentReady runtime)
    , "GATEWAYCLASS_ACCEPTED=" ++ boolText (edgeGatewayClassAccepted runtime)
    , "GATEWAY_READY=" ++ boolText (edgeGatewayReady runtime)
    , "AUTH_HTTPROUTE_ACCEPTED=" ++ boolText (edgeAuthRouteAccepted runtime)
    , "VSCODE_HTTPROUTE_ACCEPTED=" ++ boolText (edgeVscodeRouteAccepted runtime)
    , "API_HTTPROUTE_ACCEPTED=" ++ boolText (edgeApiRouteAccepted runtime)
    , "WEBSOCKET_HTTPROUTE_ACCEPTED=" ++ boolText (edgeWebsocketRouteAccepted runtime)
    , "HARBOR_HTTPROUTE_ACCEPTED=" ++ boolText (edgeHarborRouteAccepted runtime)
    , "MINIO_HTTPROUTE_ACCEPTED=" ++ boolText (edgeMinioRouteAccepted runtime)
    , "VSCODE_SECURITY_POLICY_ATTACHED=" ++ boolText (edgeVscodeSecurityPolicyAttached runtime)
    , "API_SECURITY_POLICY_ATTACHED=" ++ boolText (edgeApiSecurityPolicyAttached runtime)
    , "WEBSOCKET_SECURITY_POLICY_ATTACHED=" ++ boolText (edgeWebsocketSecurityPolicyAttached runtime)
    , "HARBOR_SECURITY_POLICY_ATTACHED=" ++ boolText (edgeHarborSecurityPolicyAttached runtime)
    , "MINIO_SECURITY_POLICY_ATTACHED=" ++ boolText (edgeMinioSecurityPolicyAttached runtime)
    , "CERTIFICATE_READY=" ++ edgeCertificateReady runtime
    , "PRIVATE_EDGE_READY=" ++ boolText privateEdgeReady
    , "CLASSIFICATION=" ++ classification
    ]
 where
  publicRoute53Status
    | edgeRoute53RecordIp runtime == Just (edgePublicIp runtime) = "in-sync"
    | edgeRoute53RecordIp runtime == Nothing = "missing"
    | otherwise = "mismatch"
  coreRoutesReady =
    edgeAuthRouteAccepted runtime
      && edgeVscodeRouteAccepted runtime
      && edgeApiRouteAccepted runtime
      && edgeWebsocketRouteAccepted runtime
  adminRoutesReady =
    edgeHarborRouteAccepted runtime
      && edgeMinioRouteAccepted runtime
  corePoliciesReady =
    edgeVscodeSecurityPolicyAttached runtime
      && edgeApiSecurityPolicyAttached runtime
      && edgeWebsocketSecurityPolicyAttached runtime
  adminPoliciesReady =
    edgeHarborSecurityPolicyAttached runtime
      && edgeMinioSecurityPolicyAttached runtime
  privateEdgeReady =
    edgeEnvoyGatewayDeploymentReady runtime
      && edgeGatewayClassAccepted runtime
      && edgeGatewayReady runtime
      && coreRoutesReady
      && adminRoutesReady
      && corePoliciesReady
      && adminPoliciesReady
      && edgeCertificateReady runtime == "true"
      && edgeEnvoyServiceIp runtime /= "<missing>"
      && edgeLoadBalancerIpMatches runtime
  publicDnsStale = publicRoute53Status /= "in-sync"
  classification
    | privateEdgeReady && publicDnsStale = "private-edge-ready-public-dns-stale"
    | edgeCertificateReady runtime /= "true" = "certificate-not-ready"
    | not corePoliciesReady = "auth-policy-not-ready"
    | not adminPoliciesReady = "admin-auth-policy-not-ready"
    | not coreRoutesReady = "gateway-route-not-ready"
    | not adminRoutesReady = "admin-route-not-ready"
    | not (edgeGatewayReady runtime && edgeGatewayClassAccepted runtime) = "gateway-not-ready"
    | not (edgeEnvoyGatewayDeploymentReady runtime) = "envoy-gateway-controller-not-ready"
    | edgeEnvoyServiceIp runtime == "<missing>" = "envoy-service-not-ready"
    | not (edgeLoadBalancerIpMatches runtime) = "load-balancer-ip-drift"
    | not privateEdgeReady = "cluster-edge-not-ready"
    | otherwise = "ready-for-external-proof"

edgeLoadBalancerIpMatches :: EdgeRuntime -> Bool
edgeLoadBalancerIpMatches runtime =
  edgeExpectedLbIp runtime /= "<unknown>"
    && edgeExpectedLbIp runtime /= "<missing>"
    && edgeEnvoyServiceIp runtime == edgeExpectedLbIp runtime

runHostCheckPorts :: IO ExitCode
runHostCheckPorts = do
  listeningPortsResult <- loadListeningPorts
  case listeningPortsResult of
    Left err -> failWith err
    Right listeningPorts -> do
      let statuses = map (mkPortStatus listeningPorts) [80, 443]
      putStr (renderPortAvailabilityReport statuses)
      pure (if any (not . portAvailable) statuses then ExitFailure 1 else ExitSuccess)

mkPortStatus :: Set Int -> Int -> PortStatus
mkPortStatus listeningPorts port =
  PortStatus
    { portNumber = port
    , portAvailable = Set.notMember port listeningPorts
    , portDetail =
        if Set.member port listeningPorts
          then "listening socket detected"
          else "no listening socket detected"
    }

loadListeningPorts :: IO (Either String (Set Int))
loadListeningPorts = do
  let procPaths = ["/proc/net/tcp", "/proc/net/tcp6"]
  existingPaths <- filterM doesFileExist procPaths
  case existingPaths of
    [] -> pure (Left "Port availability check requires Linux procfs support under /proc/net/tcp.")
    _ -> do
      parsedPortSets <- mapM parseProcNetFile existingPaths
      pure (fmap Set.unions (sequence parsedPortSets))

parseProcNetFile :: FilePath -> IO (Either String (Set Int))
parseProcNetFile path = do
  contents <- readFile path
  pure (Set.fromList <$> parseProcNetContents path contents)

parseProcNetContents :: FilePath -> String -> Either String [Int]
parseProcNetContents path contents = fmap concat (mapM (parseProcNetLine path) (drop 1 (lines contents)))

parseProcNetLine :: FilePath -> String -> Either String [Int]
parseProcNetLine path rawLine =
  case words rawLine of
    (_ : localAddress : _ : state : _) | state == "0A" -> do
      port <- parseHexPort path localAddress
      Right [port]
    (_ : _ : _ : _) -> Right []
    [] -> Right []
    _ -> Left ("Could not parse procfs socket line in " ++ path ++ ": " ++ rawLine)

parseHexPort :: FilePath -> String -> Either String Int
parseHexPort path localAddress =
  case break (== ':') localAddress of
    (_, ':' : rawPort) ->
      case readHex rawPort of
        [(port, "")] -> Right port
        _ -> Left ("Could not parse listening port in " ++ path ++ ": " ++ localAddress)
    _ -> Left ("Could not find port separator in " ++ path ++ ": " ++ localAddress)

runSingleEffect :: FilePath -> String -> Effect -> IO ExitCode
runSingleEffect repoRoot failureContext effect = do
  effectResult <- runEffect (InterpreterContext repoRoot) effect
  case effectResult of
    Failure err -> failWith (failureContext ++ ": " ++ err)
    Success () -> pure ExitSuccess

-- | Print host system information including NTP synchronization
-- disposition.  Fails fast when the host is reachable via @timedatectl@
-- but reports unsynchronized clocks, since every freshness judgement and
-- claim/yield ordering check in the gateway daemon compares wall-clock UTC
-- stamps across nodes.
runHostInfo :: FilePath -> IO ExitCode
runHostInfo repoRoot = do
  unameOutput <- captureCommand (CommandSpec "uname" ["-a"] Nothing (Just repoRoot))
  let unameLine = case unameOutput of
        Failure err -> "uname unavailable: " ++ err
        Success out -> case processExitCode out of
          ExitSuccess -> trim (processStdout out)
          ExitFailure _ -> "uname failed: " ++ trim (processStderr out)
  ntp <- detectNtpDisposition repoRoot
  putStr (renderHostInfoReport unameLine ntp)
  case ntp of
    NtpSynchronized -> pure ExitSuccess
    NtpUnknown _ -> pure ExitSuccess
    NtpUnsynced detail ->
      failWith ("Host NTP synchronization is unhealthy: " ++ detail)

-- | Render the operator-facing host-info disposition.  Tested directly so
-- documentation and integration coverage can rely on stable output.
renderHostInfoReport :: String -> NtpDisposition -> String
renderHostInfoReport unameLine ntp =
  unlines
    [ "Host info"
    , "UNAME=" ++ unameLine
    , "NTP_STATUS=" ++ ntpStatusLabel ntp
    , "NTP_DETAIL=" ++ ntpDetail ntp
    ]
 where
  ntpStatusLabel :: NtpDisposition -> String
  ntpStatusLabel NtpSynchronized = "synchronized"
  ntpStatusLabel (NtpUnsynced _) = "unsynced"
  ntpStatusLabel (NtpUnknown _) = "unknown"

  ntpDetail :: NtpDisposition -> String
  ntpDetail NtpSynchronized = "system clock is synchronized to a time source"
  ntpDetail (NtpUnsynced detail) = detail
  ntpDetail (NtpUnknown detail) = detail

-- | Inspect the host's NTP state via @timedatectl status@. Returns
-- 'NtpUnknown' when @timedatectl@ is not available so non-systemd test
-- hosts (or chroots) do not block development workflows.
detectNtpDisposition :: FilePath -> IO NtpDisposition
detectNtpDisposition repoRoot = do
  timedatectl <- findExecutable "timedatectl"
  case timedatectl of
    Nothing -> pure (NtpUnknown "timedatectl is not available on this host")
    Just _ -> do
      outputResult <-
        captureCommand
          (CommandSpec "timedatectl" ["status"] Nothing (Just repoRoot))
      case outputResult of
        Failure err -> pure (NtpUnknown ("timedatectl invocation failed: " ++ err))
        Success out -> case processExitCode out of
          ExitSuccess -> pure (parseTimedatectlNtpDisposition (processStdout out))
          ExitFailure code ->
            pure
              ( NtpUnknown
                  ( "timedatectl exited "
                      ++ show code
                      ++ ": "
                      ++ trim (processStderr out)
                  )
              )

-- | Pure helper that parses @timedatectl status@ output into a
-- 'NtpDisposition'. Recognizes the supported Ubuntu 24.04
-- @System clock synchronized: yes/no@ field.
parseTimedatectlNtpDisposition :: String -> NtpDisposition
parseTimedatectlNtpDisposition raw =
  let fieldLines = lines raw
      synchronized = lookupField fieldLines "system clock synchronized"
   in case synchronized of
        Just value
          | normalize value == "yes" -> NtpSynchronized
          | normalize value == "no" ->
              NtpUnsynced "timedatectl reports system clock not synchronized"
          | otherwise -> NtpUnknown ("unrecognized timedatectl value: " ++ value)
        Nothing -> NtpUnknown "timedatectl output did not include synchronization state"
 where
  lookupField :: [String] -> String -> Maybe String
  lookupField items needle =
    case filter (\l -> map toLowerAscii (trim l) `startsWith` needle) items of
      [] -> Nothing
      (l : _) -> case break (== ':') (trim l) of
        (_, ':' : value) -> Just (trim value)
        _ -> Nothing

  startsWith :: String -> String -> Bool
  startsWith haystack needle = take (length needle) haystack == needle

  normalize :: String -> String
  normalize = map toLowerAscii . trim

runPrerequisites :: FilePath -> [String] -> IO (Result ())
runPrerequisites repoRoot rootIds =
  case fromRootIds rootIds prerequisiteRegistry of
    Left err -> pure (Failure err)
    Right dag -> runEffectDAG (InterpreterContext repoRoot) dag

commandEffect :: FilePath -> [String] -> FilePath -> Effect
commandEffect commandPath commandArguments repoRoot =
  RunCommand
    CommandSpec
      { commandPath = commandPath
      , commandArguments = commandArguments
      , commandEnvironment = Nothing
      , commandWorkingDirectory = Just repoRoot
      }

optionalKubectlJson :: FilePath -> Maybe String -> [String] -> IO (Either String (Maybe Value))
optionalKubectlJson repoRoot maybeNamespace args = do
  outputResult <-
    captureCommand
      CommandSpec
        { commandPath = "kubectl"
        , commandArguments = namespaceArgs ++ args
        , commandEnvironment = Nothing
        , commandWorkingDirectory = Just repoRoot
        }
  pure $
    case outputResult of
      Failure err -> if isOptionalAbsence err then Right Nothing else Left err
      Success output ->
        case processExitCode output of
          ExitSuccess ->
            let trimmed = trim (processStdout output)
             in if trimmed == "" then Right Nothing else Just <$> eitherDecode (BL8.pack trimmed)
          ExitFailure _ ->
            let detail = commandFailure output
             in if isOptionalAbsence detail then Right Nothing else Left detail
 where
  namespaceArgs = maybe [] (\namespace -> ["--namespace", namespace]) maybeNamespace

commandFailure :: ProcessOutput -> String
commandFailure output =
  case (trim (processStderr output), trim (processStdout output)) of
    (stderrText, _) | stderrText /= "" -> stderrText
    ("", stdoutText) | stdoutText /= "" -> stdoutText
    _ -> "subprocess exited without output"

edgeObject :: Maybe Value -> Maybe (KeyMap.KeyMap Value)
edgeObject maybeValue =
  case maybeValue of
    Just (Object obj) -> Just obj
    _ -> Nothing

serviceLoadBalancerIp :: Maybe Value -> String
serviceLoadBalancerIp maybeValue =
  case edgeObject maybeValue of
    Just obj ->
      case KeyMap.lookup "items" obj of
        Just (Array items) | not (Vector.null items) -> firstLoadBalancerIp (Vector.head items)
        _ -> "<missing>"
    Nothing -> "<missing>"

deploymentReady :: Maybe Value -> Bool
deploymentReady maybeValue =
  case maybeStatusObject maybeValue of
    Just statusObj ->
      let availableReplicas = numberField statusObj "availableReplicas"
          readyReplicas = numberField statusObj "readyReplicas"
       in availableReplicas > 0 && readyReplicas > 0
    Nothing -> False

gatewayClassAccepted :: Maybe Value -> Bool
gatewayClassAccepted maybeValue = hasStatusCondition maybeValue ["Accepted"]

gatewayReady :: Maybe Value -> Bool
gatewayReady maybeValue = hasStatusCondition maybeValue ["Accepted", "Programmed", "Ready"]

httpRouteAccepted :: Maybe Value -> Bool
httpRouteAccepted maybeValue =
  case maybeValue of
    Just (Object obj) ->
      case KeyMap.lookup "status" obj of
        Just (Object statusObj) ->
          case KeyMap.lookup "parents" statusObj of
            Just (Array parents) -> any parentAccepted (Vector.toList parents)
            _ -> False
        _ -> False
    _ -> False
 where
  parentAccepted parentValue =
    case parentValue of
      Object parentObj ->
        case KeyMap.lookup "conditions" parentObj of
          Just (Array conditions) -> any conditionAccepted (Vector.toList conditions)
          _ -> False
      _ -> False
  conditionAccepted conditionValue =
    case conditionValue of
      Object conditionObj ->
        case (KeyMap.lookup "type" conditionObj, KeyMap.lookup "status" conditionObj) of
          (Just (String "Accepted"), Just (String "True")) -> True
          _ -> False
      _ -> False

securityPolicyAttached :: Text.Text -> Maybe Value -> Bool
securityPolicyAttached routeName maybeValue =
  case maybeValue of
    Just (Object obj) ->
      hasTargetRef obj
        && ( hasStatusCondition maybeValue ["Accepted", "Programmed"] || not (hasAnyStatusConditions maybeValue)
           )
    _ -> False
 where
  hasTargetRef obj =
    case KeyMap.lookup "spec" obj of
      Just (Object specObj) ->
        case KeyMap.lookup "targetRefs" specObj of
          Just (Array refs) -> any targetMatches (Vector.toList refs)
          _ -> False
      _ -> False
  targetMatches value =
    case value of
      Object refObj ->
        KeyMap.lookup "kind" refObj == Just (String "HTTPRoute")
          && KeyMap.lookup "name" refObj == Just (String routeName)
      _ -> False

maybeStatusObject :: Maybe Value -> Maybe (KeyMap.KeyMap Value)
maybeStatusObject maybeValue =
  case maybeValue of
    Just (Object obj) ->
      case KeyMap.lookup "status" obj of
        Just (Object statusObj) -> Just statusObj
        _ -> Nothing
    _ -> Nothing

hasAnyStatusConditions :: Maybe Value -> Bool
hasAnyStatusConditions maybeValue =
  case maybeStatusObject maybeValue of
    Just statusObj ->
      case KeyMap.lookup "conditions" statusObj of
        Just (Array conditions) -> not (Vector.null conditions)
        _ -> False
    Nothing -> False

hasStatusCondition :: Maybe Value -> [Text.Text] -> Bool
hasStatusCondition maybeValue acceptedTypes =
  case maybeStatusObject maybeValue of
    Just statusObj ->
      case KeyMap.lookup "conditions" statusObj of
        Just (Array conditions) -> any conditionAccepted (Vector.toList conditions)
        _ -> False
    Nothing -> False
 where
  conditionAccepted value =
    case value of
      Object conditionObj ->
        case (KeyMap.lookup "type" conditionObj, KeyMap.lookup "status" conditionObj) of
          (Just (String conditionType), Just (String "True")) -> conditionType `elem` acceptedTypes
          _ -> False
      _ -> False

numberField :: KeyMap.KeyMap Value -> Text.Text -> Int
numberField obj fieldName =
  case KeyMap.lookup (Key.fromText fieldName) obj of
    Just (Number value) -> round value
    _ -> 0

firstLoadBalancerIp :: Value -> String
firstLoadBalancerIp value =
  case value of
    Object obj ->
      case KeyMap.lookup "status" obj of
        Just (Object statusObj) ->
          case KeyMap.lookup "loadBalancer" statusObj of
            Just (Object lbObj) ->
              case KeyMap.lookup "ingress" lbObj of
                Just (Array ingressItems) | not (Vector.null ingressItems) -> firstIpLike (Vector.head ingressItems)
                _ -> "<missing>"
            _ -> "<missing>"
        _ -> "<missing>"
    _ -> "<missing>"

firstIpLike :: Value -> String
firstIpLike value =
  case value of
    Object obj ->
      case KeyMap.lookup "ip" obj of
        Just (String ipText) -> Text.unpack ipText
        _ ->
          case KeyMap.lookup "hostname" obj of
            Just (String hostText) -> Text.unpack hostText
            _ -> "<missing>"
    _ -> "<missing>"

certificateReady :: Maybe Value -> String
certificateReady maybeValue =
  case maybeValue of
    Nothing -> "missing"
    Just (Object obj) ->
      case KeyMap.lookup "status" obj of
        Just (Object statusObj) ->
          case KeyMap.lookup "conditions" statusObj of
            Just (Array conditions) -> conditionReady (Vector.toList conditions)
            _ -> "unknown"
        _ -> "unknown"
    _ -> "unknown"

conditionReady :: [Value] -> String
conditionReady [] = "unknown"
conditionReady (value : remaining) =
  case value of
    Object obj ->
      case (KeyMap.lookup "type" obj, KeyMap.lookup "status" obj) of
        (Just (String "Ready"), Just (String "True")) -> "true"
        (Just (String "Ready"), Just (String "False")) -> "false"
        _ -> conditionReady remaining
    _ -> conditionReady remaining

firstFailure :: [Either String ()] -> Maybe String
firstFailure [] = Nothing
firstFailure (result : remaining) =
  case result of
    Left err -> Just err
    Right _ -> firstFailure remaining

toUnit :: Either String a -> Either String ()
toUnit value =
  case value of
    Left err -> Left err
    Right _ -> Right ()

isOptionalAbsence :: String -> Bool
isOptionalAbsence errorText =
  let lowered = map toLowerAscii errorText
   in "notfound" `contains` lowered
        || "not found" `contains` lowered
        || "the server doesn't have a resource type" `contains` lowered
        || "could not find the requested resource" `contains` lowered
        || "no matches for kind" `contains` lowered

detectLanAddressing :: IO (Either String LanAddressing)
detectLanAddressing = do
  ipExists <- findExecutable "ip"
  case ipExists of
    Nothing -> pure (Right fallbackLanAddressing)
    Just _ -> do
      routeResult <-
        captureCommand
          CommandSpec
            { commandPath = "ip"
            , commandArguments = ["-j", "-4", "route", "show", "default"]
            , commandEnvironment = Nothing
            , commandWorkingDirectory = Nothing
            }
      case routeResult of
        Failure _ -> pure (Right fallbackLanAddressing)
        Success routeOutput ->
          case processExitCode routeOutput of
            ExitFailure _ -> pure (Right fallbackLanAddressing)
            ExitSuccess ->
              case decodeInterfaceName (processStdout routeOutput) of
                Nothing -> pure (Right fallbackLanAddressing)
                Just interfaceName -> do
                  addrResult <-
                    captureCommand
                      CommandSpec
                        { commandPath = "ip"
                        , commandArguments = ["-j", "-4", "addr", "show", "dev", interfaceName]
                        , commandEnvironment = Nothing
                        , commandWorkingDirectory = Nothing
                        }
                  case addrResult of
                    Failure _ -> pure (Right fallbackLanAddressing)
                    Success addrOutput ->
                      case processExitCode addrOutput of
                        ExitFailure _ -> pure (Right fallbackLanAddressing)
                        ExitSuccess -> pure (decodeLanAddressing interfaceName (processStdout addrOutput))

decodeInterfaceName :: String -> Maybe String
decodeInterfaceName stdoutText =
  case eitherDecode (BL8.pack stdoutText) :: Either String Value of
    Left _ -> Nothing
    Right (Array values) | not (Vector.null values) ->
      case Vector.head values of
        Object obj ->
          case KeyMap.lookup "dev" obj of
            Just (String value) -> Just (Text.unpack value)
            _ -> Nothing
        _ -> Nothing
    _ -> Nothing

decodeLanAddressing :: String -> String -> Either String LanAddressing
decodeLanAddressing interfaceName stdoutText = do
  payload <- eitherDecode (BL8.pack stdoutText) :: Either String Value
  case payload of
    Array values | not (Vector.null values) ->
      case Vector.head values of
        Object obj -> do
          addrInfo <- case KeyMap.lookup "addr_info" obj of
            Just (Array info) -> Right (Vector.toList info)
            _ -> Left "missing addr_info"
          case firstInet addrInfo of
            Just (ipv4Text, prefixLength) -> do
              let networkCidr = ipv4Text ++ "/" ++ show prefixLength
              (metallbPool, ingressLbIp) <- selectMetallbRange ipv4Text prefixLength
              Right
                LanAddressing
                  { lanInterfaceName = interfaceName
                  , lanInterfaceIpv4 = ipv4Text
                  , lanNetworkCidr = networkCidr
                  , lanMetallbPool = metallbPool
                  , lanIngressLbIp = ingressLbIp
                  }
            Nothing -> Left "no IPv4 addr_info entry found"
        _ -> Left "unexpected ip addr payload"
    _ -> Left "unexpected ip addr payload"

firstInet :: [Value] -> Maybe (String, Int)
firstInet [] = Nothing
firstInet (value : remaining) =
  case value of
    Object obj ->
      case (KeyMap.lookup "family" obj, KeyMap.lookup "local" obj, KeyMap.lookup "prefixlen" obj) of
        (Just (String "inet"), Just (String localValue), Just (Number prefixValue)) ->
          let prefixLength = round prefixValue
           in if prefixValue == fromIntegral prefixLength
                then Just (Text.unpack localValue, prefixLength)
                else firstInet remaining
        _ -> firstInet remaining
    _ -> firstInet remaining

selectMetallbRange :: String -> Int -> Either String (String, String)
selectMetallbRange ipv4Text prefixLength = do
  interfaceIp <- ipv4ToWord32 ipv4Text
  if prefixLength < 0 || prefixLength > 32 then Left "invalid prefix length" else Right ()
  let fullMask = 4294967295 :: Integer
      mask = if prefixLength == 0 then 0 else fullMask `xor` ((1 `shiftL` (32 - prefixLength)) - 1)
      hostMask = fullMask `xor` mask
      networkAddress = interfaceIp .&. mask
      broadcastAddress = networkAddress .|. hostMask
      minHost = networkAddress + 1
      maxHost = broadcastAddress - 1
      poolSize = 11
      preferredStart = networkAddress + 240
      preferredEnd = preferredStart + poolSize - 1
      preferredUsable =
        preferredStart >= minHost
          && preferredEnd <= maxHost
          && not (interfaceIp >= preferredStart && interfaceIp <= preferredEnd)
      (start0, end0) = if preferredUsable then (preferredStart, preferredEnd) else (maxHost - poolSize + 1, maxHost)
      (start, end) =
        if interfaceIp >= start0 && interfaceIp <= end0
          then (interfaceIp - poolSize, interfaceIp - 1)
          else (start0, end0)
   in if maxHost - minHost + 1 < fromIntegral poolSize || start < minHost
        then Left "active subnet is too small for the default MetalLB pool"
        else do
          startText <- word32ToIpv4 start
          endText <- word32ToIpv4 end
          Right (startText ++ "-" ++ endText, startText)

contains :: String -> String -> Bool
contains needle haystack = any (needle `prefixOf`) (tails haystack)

prefixOf :: String -> String -> Bool
prefixOf [] _ = True
prefixOf _ [] = False
prefixOf (left : leftRest) (right : rightRest) = left == right && prefixOf leftRest rightRest

tails :: String -> [String]
tails [] = [[]]
tails value@(_ : remaining) = value : tails remaining

toLowerAscii :: Char -> Char
toLowerAscii character
  | isAsciiUpper character = toEnum (fromEnum character + 32)
  | otherwise = character

ipv4ToWord32 :: String -> Either String Integer
ipv4ToWord32 value =
  case map readMaybeInt (splitOn '.' value) of
    [Just a, Just b, Just c, Just d]
      | all (\segment -> segment >= 0 && segment <= 255) [a, b, c, d] ->
          Right
            ( fromIntegral a * 256 ^ (3 :: Integer)
                + fromIntegral b * 256 ^ (2 :: Integer)
                + fromIntegral c * 256
                + fromIntegral d
            )
    _ -> Left ("invalid IPv4 address: " ++ value)

word32ToIpv4 :: Integer -> Either String String
word32ToIpv4 value
  | value < 0 || value > 4294967295 = Left "invalid IPv4 integer"
  | otherwise =
      Right
        ( show ((value `div` 256 ^ (3 :: Integer)) `mod` 256)
            ++ "."
            ++ show ((value `div` 256 ^ (2 :: Integer)) `mod` 256)
            ++ "."
            ++ show ((value `div` 256) `mod` 256)
            ++ "."
            ++ show (value `mod` 256)
        )

readMaybeInt :: String -> Maybe Int
readMaybeInt value =
  case reads value of
    [(parsed, "")] -> Just parsed
    _ -> Nothing

splitOn :: Char -> String -> [String]
splitOn _ [] = [""]
splitOn delimiter value = go value "" []
 where
  go [] current acc = reverse (reverse current : acc)
  go (character : remaining) current acc
    | character == delimiter = go remaining "" (reverse current : acc)
    | otherwise = go remaining (character : current) acc

fallbackLanAddressing :: LanAddressing
fallbackLanAddressing =
  LanAddressing
    { lanInterfaceName = "<unknown>"
    , lanInterfaceIpv4 = "<unknown>"
    , lanNetworkCidr = "<unknown>"
    , lanMetallbPool = "<unknown>"
    , lanIngressLbIp = "<unknown>"
    }

boolText :: Bool -> String
boolText value = if value then "true" else "false"

configuredMetallbAdvertisementMode :: ValidatedSettings -> String
configuredMetallbAdvertisementMode settings =
  case fmap
    (map toLowerAscii . Text.unpack)
    (public_edge_advertisement_mode (deployment (validatedConfig settings))) of
    Just "bgp" -> "bgp"
    _ -> "l2"

commaSeparated :: [String] -> String
commaSeparated values =
  case values of
    [] -> ""
    [value] -> value
    _ -> foldr1 (\left right -> left ++ ", " ++ right) values

trim :: String -> String
trim = f . f
 where
  f = reverse . dropWhile (`elem` [' ', '\n', '\r', '\t'])

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)
