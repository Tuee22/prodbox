{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Host (
    LanAddressing (..),
    PortStatus (..),
    detectLanAddressing,
    renderPortAvailabilityReport,
    runHostCommand,
)
where

import Control.Monad (filterM)
import Data.Aeson (
    Value (..),
    eitherDecode,
 )
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bits (
    shiftL,
    xor,
    (.&.),
    (.|.),
 )
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isAsciiUpper)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Numeric (readHex)
import Prodbox.CLI.Command (HostCommand (..))
import Prodbox.Dns (
    fetchPublicIp,
    preferredPublicHostFqdn,
    queryRoute53Record,
 )
import Prodbox.Effect (Effect (..))
import Prodbox.EffectDAG (fromRootIds)
import Prodbox.EffectInterpreter (InterpreterContext (..), runEffect, runEffectDAG)
import Prodbox.Prerequisite (prerequisiteRegistry)
import Prodbox.Result (Result (..))
import Prodbox.Settings (
    ValidatedSettings (..),
    validateAndLoadSettings,
 )
import Prodbox.Subprocess (
    CommandSpec (..),
    ProcessOutput (..),
    captureCommand,
 )
import System.Directory (doesFileExist, findExecutable)
import System.Exit (ExitCode (..))
import System.IO (hPutStrLn, stderr)

data PortStatus = PortStatus
    { portNumber :: Int
    , portAvailable :: Bool
    , portDetail :: String
    }
    deriving (Eq, Show)

data EdgeRuntime = EdgeRuntime
    { edgePublicIp :: String
    , edgeRoute53RecordIp :: Maybe String
    , edgeActiveLanInterface :: String
    , edgeActiveLanIpv4 :: String
    , edgeActiveLanCidr :: String
    , edgeMetallbPool :: String
    , edgeIngressLbIp :: String
    , edgeTraefikServiceIp :: String
    , edgeHasTraefikClass :: Bool
    , edgeHasNginxClass :: Bool
    , edgeIngressNginxServices :: Int
    , edgeVscodeIngressClass :: String
    , edgeVscodeIngressHost :: String
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
        HostInfo -> runSingleEffect repoRoot "Get host system information" (commandEffect "uname" ["-a"] repoRoot)
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
                    route53Result <- queryRoute53Record repoRoot settings (preferredPublicHostFqdn settings)
                    case route53Result of
                        Left err -> failWith err
                        Right route53RecordIp -> do
                            lanResult <- detectLanAddressing
                            ingressClassesResult <- kubectlJson repoRoot Nothing ["get", "ingressclass", "-o", "json"]
                            traefikServiceResult <- optionalKubectlJson repoRoot (Just "traefik-system") ["get", "svc", "-l", "app.kubernetes.io/name=traefik", "-o", "json"]
                            ingressNginxResult <- kubectlJson repoRoot Nothing ["get", "svc", "-A", "-l", "app.kubernetes.io/name=ingress-nginx", "-o", "json"]
                            vscodeIngressResult <- optionalKubectlJson repoRoot (Just "vscode") ["get", "ingress", "vscode", "-o", "json", "--ignore-not-found=true"]
                            certificateResult <- optionalKubectlJson repoRoot (Just "vscode") ["get", "certificate", "vscode-tls", "-o", "json", "--ignore-not-found=true"]
                            case firstFailure [toUnit lanResult, toUnit ingressClassesResult, toUnit traefikServiceResult, toUnit ingressNginxResult, toUnit vscodeIngressResult, toUnit certificateResult] of
                                Just err -> failWith err
                                Nothing ->
                                    case (lanResult, ingressClassesResult, traefikServiceResult, ingressNginxResult, vscodeIngressResult, certificateResult) of
                                        (Right lan, Right ingressClassesDoc, Right traefikServiceDoc, Right ingressNginxDoc, Right vscodeIngressDoc, Right certificateDoc) -> do
                                            let runtime =
                                                    EdgeRuntime
                                                        { edgePublicIp = publicIp
                                                        , edgeRoute53RecordIp = route53RecordIp
                                                        , edgeActiveLanInterface = lanInterfaceName lan
                                                        , edgeActiveLanIpv4 = lanInterfaceIpv4 lan
                                                        , edgeActiveLanCidr = lanNetworkCidr lan
                                                        , edgeMetallbPool = lanMetallbPool lan
                                                        , edgeIngressLbIp = lanIngressLbIp lan
                                                        , edgeTraefikServiceIp = traefikServiceIp traefikServiceDoc
                                                        , edgeHasTraefikClass = ingressClassPresent ingressClassesDoc "traefik"
                                                        , edgeHasNginxClass = ingressClassPresent ingressClassesDoc "nginx"
                                                        , edgeIngressNginxServices = serviceCount ingressNginxDoc
                                                        , edgeVscodeIngressClass = vscodeIngressClass vscodeIngressDoc
                                                        , edgeVscodeIngressHost = vscodeIngressHost vscodeIngressDoc
                                                        , edgeCertificateReady = certificateReady certificateDoc
                                                        }
                                            putStr (renderPublicEdgeReport settings runtime)
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

renderPublicEdgeReport :: ValidatedSettings -> EdgeRuntime -> String
renderPublicEdgeReport settings runtime =
    unlines
        [ "Public edge diagnostic"
        , "FQDN=" ++ preferredPublicHostFqdn settings
        , "PUBLIC_IP=" ++ edgePublicIp runtime
        , "ROUTE53_A_RECORD=" ++ maybe "<missing>" id (edgeRoute53RecordIp runtime)
        , "ROUTE53_STATUS=" ++ route53Status
        , "ACTIVE_LAN_INTERFACE=" ++ edgeActiveLanInterface runtime
        , "ACTIVE_LAN_IPV4=" ++ edgeActiveLanIpv4 runtime
        , "ACTIVE_LAN_CIDR=" ++ edgeActiveLanCidr runtime
        , "METALLB_POOL=" ++ edgeMetallbPool runtime
        , "INGRESS_LB_IP=" ++ edgeIngressLbIp runtime
        , "TRAEFIK_SERVICE_IP=" ++ edgeTraefikServiceIp runtime
        , "INGRESSCLASS_TRAEFIK=" ++ presentText (edgeHasTraefikClass runtime)
        , "INGRESSCLASS_NGINX=" ++ presentText (edgeHasNginxClass runtime)
        , "INGRESS_NGINX_SERVICES=" ++ show (edgeIngressNginxServices runtime)
        , "VSCODE_INGRESS_CLASS=" ++ edgeVscodeIngressClass runtime
        , "VSCODE_INGRESS_HOST=" ++ edgeVscodeIngressHost runtime
        , "CERTIFICATE_READY=" ++ edgeCertificateReady runtime
        , "PRIVATE_EDGE_READY=" ++ boolText privateEdgeReady
        , "CLASSIFICATION=" ++ classification
        ]
  where
    route53Status
        | edgeRoute53RecordIp runtime == Just (edgePublicIp runtime) = "in-sync"
        | edgeRoute53RecordIp runtime == Nothing = "missing"
        | otherwise = "mismatch"
    privateEdgeReady =
        edgeHasTraefikClass runtime
            && not (edgeHasNginxClass runtime)
            && edgeIngressNginxServices runtime == 0
            && edgeVscodeIngressClass runtime == "traefik"
            && edgeCertificateReady runtime == "true"
            && edgeTraefikServiceIp runtime /= "<missing>"
    classification
        | privateEdgeReady && route53Status /= "in-sync" = "private-edge-ready-public-dns-stale"
        | edgeHasNginxClass runtime || edgeIngressNginxServices runtime > 0 = "competing-ingress-controller"
        | edgeCertificateReady runtime /= "true" = "certificate-not-ready"
        | edgeVscodeIngressClass runtime /= "traefik" = "vscode-ingress-class-drift"
        | not privateEdgeReady = "cluster-edge-not-ready"
        | otherwise = "ready-for-external-proof"

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

kubectlJson :: FilePath -> Maybe String -> [String] -> IO (Either String Value)
kubectlJson repoRoot maybeNamespace args = do
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
            Failure err -> Left err
            Success output ->
                case processExitCode output of
                    ExitSuccess -> eitherDecode (BL8.pack (processStdout output))
                    ExitFailure _ -> Left (commandFailure output)
  where
    namespaceArgs = maybe [] (\namespace -> ["--namespace", namespace]) maybeNamespace

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

edgeItems :: Value -> [Value]
edgeItems value =
    case value of
        Object obj ->
            case KeyMap.lookup "items" obj of
                Just (Array items) -> Vector.toList items
                _ -> []
        _ -> []

ingressClassPresent :: Value -> String -> Bool
ingressClassPresent value className = any matches (edgeItems value)
  where
    matches item =
        case item of
            Object obj ->
                case KeyMap.lookup "metadata" obj of
                    Just (Object metadataObj) -> KeyMap.lookup "name" metadataObj == Just (String (Text.pack className))
                    _ -> False
            _ -> False

serviceCount :: Value -> Int
serviceCount value = length (edgeItems value)

traefikServiceIp :: Maybe Value -> String
traefikServiceIp maybeValue =
    case edgeObject maybeValue of
        Just obj ->
            case KeyMap.lookup "items" obj of
                Just (Array items) | not (Vector.null items) -> firstLoadBalancerIp (Vector.head items)
                _ -> "<missing>"
        Nothing -> "<missing>"

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

vscodeIngressClass :: Maybe Value -> String
vscodeIngressClass maybeValue =
    case maybeValue of
        Just (Object obj) ->
            case KeyMap.lookup "spec" obj of
                Just (Object specObj) ->
                    case KeyMap.lookup "ingressClassName" specObj of
                        Just (String value) -> Text.unpack value
                        _ -> "<missing>"
                _ -> "<missing>"
        _ -> "<missing>"

vscodeIngressHost :: Maybe Value -> String
vscodeIngressHost maybeValue =
    case maybeValue of
        Just (Object obj) ->
            case KeyMap.lookup "spec" obj of
                Just (Object specObj) ->
                    case KeyMap.lookup "rules" specObj of
                        Just (Array rules) | not (Vector.null rules) ->
                            case Vector.head rules of
                                Object firstRule ->
                                    case KeyMap.lookup "host" firstRule of
                                        Just (String value) -> Text.unpack value
                                        _ -> "<missing>"
                                _ -> "<missing>"
                        _ -> "<missing>"
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
        preferredUsable = preferredStart >= minHost && preferredEnd <= maxHost && not (interfaceIp >= preferredStart && interfaceIp <= preferredEnd)
        (start0, end0) = if preferredUsable then (preferredStart, preferredEnd) else (maxHost - poolSize + 1, maxHost)
        (start, end) = if interfaceIp >= start0 && interfaceIp <= end0 then (interfaceIp - poolSize, interfaceIp - 1) else (start0, end0)
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
                Right (fromIntegral a * 256 ^ (3 :: Integer) + fromIntegral b * 256 ^ (2 :: Integer) + fromIntegral c * 256 + fromIntegral d)
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

presentText :: Bool -> String
presentText True = "present"
presentText False = "missing"

boolText :: Bool -> String
boolText value = if value then "true" else "false"

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
    hPutStrLn stderr message
    pure (ExitFailure 1)
