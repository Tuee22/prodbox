{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Settings
  ( AcmeSection (..)
  , ConfigFile (..)
  , Credentials (..)
  , DeploymentSection (..)
  , DomainSection (..)
  , MetallbBgpPeer (..)
  , Route53Section (..)
  , StorageSection (..)
  , ValidatedSettings (..)
  , defaultConfigFile
  , loadConfigFile
  , renderConfigDhall
  , renderSettingsDisplay
  , supportedPublicHostname
  , validateAwsBootstrapConfig
  , validateAndLoadSettings
  , validatePublicEdgeDeployment
  )
where

import Data.Aeson (FromJSON, ToJSON, eitherDecode)
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isDigit, isHexDigit, toLower)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Repo
  ( ConfigPaths (..)
  , canonicalConfigPaths
  )
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( CommandSpec (..)
  , ProcessOutput (..)
  , captureCommand
  )
import System.Directory
  ( doesFileExist
  , makeAbsolute
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

data Credentials = Credentials
  { access_key_id :: Text
  , secret_access_key :: Text
  , session_token :: Maybe Text
  , region :: Text
  }
  deriving (Eq, Show, Generic, FromJSON, ToJSON)

data Route53Section = Route53Section
  { zone_id :: Text
  }
  deriving (Eq, Show, Generic, FromJSON, ToJSON)

data DomainSection = DomainSection
  { demo_fqdn :: Text
  , demo_ttl :: Natural
  }
  deriving (Eq, Show, Generic, FromJSON, ToJSON)

data MetallbBgpPeer = MetallbBgpPeer
  { peer_name :: Text
  , peer_address :: Text
  , peer_asn :: Natural
  , my_asn :: Natural
  , ebgp_multi_hop :: Maybe Bool
  }
  deriving (Eq, Show, Generic, FromJSON, ToJSON)

data AcmeSection = AcmeSection
  { email :: Text
  , server :: Text
  , eab_key_id :: Maybe Text
  , eab_hmac_key :: Maybe Text
  }
  deriving (Eq, Show, Generic, FromJSON, ToJSON)

data DeploymentSection = DeploymentSection
  { dev_mode :: Bool
  , bootstrap_public_ip_override :: Maybe Text
  , pulumi_enable_dns_bootstrap :: Bool
  , public_edge_advertisement_mode :: Maybe Text
  , public_edge_bgp_peers :: Maybe [MetallbBgpPeer]
  , envoy_gateway_controller_replicas :: Maybe Natural
  , envoy_gateway_data_plane_replicas :: Maybe Natural
  , api_replicas :: Maybe Natural
  , websocket_replicas :: Maybe Natural
  }
  deriving (Eq, Show, Generic, FromJSON, ToJSON)

data StorageSection = StorageSection
  { manual_pv_host_root :: Text
  }
  deriving (Eq, Show, Generic, FromJSON, ToJSON)

data ConfigFile = ConfigFile
  { aws :: Credentials
  , aws_admin_for_test_simulation :: Credentials
  , route53 :: Route53Section
  , domain :: DomainSection
  , acme :: AcmeSection
  , deployment :: DeploymentSection
  , storage :: StorageSection
  }
  deriving (Eq, Show, Generic, FromJSON, ToJSON)

data ValidatedSettings = ValidatedSettings
  { validatedConfig :: ConfigFile
  , resolvedManualPvHostRoot :: FilePath
  }
  deriving (Eq, Show)

supportedPublicHostname :: Text
supportedPublicHostname = "test.resolvefintech.com"

validateAndLoadSettings :: FilePath -> IO (Either String ValidatedSettings)
validateAndLoadSettings repoRoot = do
  configResult <- loadConfigFile repoRoot
  case configResult of
    Left err -> pure (Left err)
    Right config -> validateConfig repoRoot config

renderSettingsDisplay :: Bool -> ValidatedSettings -> String
renderSettingsDisplay showSecrets settings =
  unlines
    [ "aws.region=" ++ renderText (region (aws config))
    , "aws.access_key_id=" ++ renderSensitive showSecrets (access_key_id (aws config))
    , "aws.secret_access_key=" ++ renderSensitive showSecrets (secret_access_key (aws config))
    , "aws.session_token=" ++ renderSensitiveMaybe showSecrets (session_token (aws config))
    , "aws_admin_for_test_simulation.access_key_id="
        ++ renderSensitiveMaybe
          showSecrets
          (normalizeOptionalText (access_key_id (aws_admin_for_test_simulation config)))
    , "aws_admin_for_test_simulation.secret_access_key="
        ++ renderSensitiveMaybe
          showSecrets
          (normalizeOptionalText (secret_access_key (aws_admin_for_test_simulation config)))
    , "aws_admin_for_test_simulation.session_token="
        ++ renderSensitiveMaybe
          showSecrets
          (normalizeMaybeText (session_token (aws_admin_for_test_simulation config)))
    , "aws_admin_for_test_simulation.region="
        ++ renderMaybeText (normalizeOptionalText (region (aws_admin_for_test_simulation config)))
    , "route53.zone_id=" ++ renderText (zone_id (route53 config))
    , "domain.demo_fqdn=" ++ renderText (demo_fqdn (domain config))
    , "domain.demo_ttl=" ++ show (demo_ttl (domain config))
    , "acme.email=" ++ renderSensitive showSecrets (email (acme config))
    , "acme.server=" ++ renderText (server (acme config))
    , "acme.eab_key_id=" ++ renderMaybeText (eab_key_id (acme config))
    , "acme.eab_hmac_key=" ++ renderSensitiveMaybe showSecrets (eab_hmac_key (acme config))
    , "deployment.dev_mode=" ++ renderBool (dev_mode (deployment config))
    , "deployment.bootstrap_public_ip_override="
        ++ renderMaybeText (bootstrap_public_ip_override (deployment config))
    , "deployment.pulumi_enable_dns_bootstrap="
        ++ renderBool (pulumi_enable_dns_bootstrap (deployment config))
    , "deployment.public_edge_advertisement_mode="
        ++ renderMaybeText (public_edge_advertisement_mode (deployment config))
    , "deployment.public_edge_bgp_peers=" ++ renderBgpPeers (public_edge_bgp_peers (deployment config))
    , "deployment.envoy_gateway_controller_replicas="
        ++ renderMaybeNatural (envoy_gateway_controller_replicas (deployment config))
    , "deployment.envoy_gateway_data_plane_replicas="
        ++ renderMaybeNatural (envoy_gateway_data_plane_replicas (deployment config))
    , "deployment.api_replicas=" ++ renderMaybeNatural (api_replicas (deployment config))
    , "deployment.websocket_replicas=" ++ renderMaybeNatural (websocket_replicas (deployment config))
    , "storage.manual_pv_host_root=" ++ resolvedManualPvHostRoot settings
    ]
 where
  config = validatedConfig settings

loadConfigFile :: FilePath -> IO (Either String ConfigFile)
loadConfigFile repoRoot = do
  let paths = canonicalConfigPaths repoRoot
      configPath = configDhallPath paths
  configExists <- doesFileExist configPath
  if not configExists
    then pure (Left (missingConfigMessage configPath))
    else do
      outputResult <-
        captureCommand
          CommandSpec
            { commandPath = "dhall-to-json"
            , commandArguments = ["--file", configPath, "--compact", "--preserve-null"]
            , commandEnvironment = Nothing
            , commandWorkingDirectory = Just repoRoot
            }
      pure $
        case outputResult of
          Failure err ->
            Left
              ( "Failed to run `dhall-to-json` for `"
                  ++ configPath
                  ++ "`: "
                  ++ err
              )
          Success output ->
            case processExitCode output of
              ExitFailure _ ->
                Left (processStderr output ++ processStdout output)
              ExitSuccess ->
                case eitherDecode (BL8.pack (processStdout output)) of
                  Left err ->
                    Left
                      ( "Failed to decode JSON from `dhall-to-json` for `"
                          ++ configPath
                          ++ "`: "
                          ++ err
                      )
                  Right config -> Right config

validateConfig :: FilePath -> ConfigFile -> IO (Either String ValidatedSettings)
validateConfig repoRoot config = do
  resolvedManualRoot <- makeAbsolute (repoRoot </> Text.unpack (manual_pv_host_root (storage config)))
  pure $ do
    validateAwsBootstrapConfig config
    requireNonEmpty "aws.access_key_id" (access_key_id (aws config))
    requireNonEmpty "aws.secret_access_key" (secret_access_key (aws config))
    pure
      ValidatedSettings
        { validatedConfig = config
        , resolvedManualPvHostRoot = resolvedManualRoot
        }

validateAwsBootstrapConfig :: ConfigFile -> Either String ()
validateAwsBootstrapConfig config = do
  requireNonEmpty "route53.zone_id" (zone_id (route53 config))
  requireNonEmpty "acme.email" (email (acme config))
  validateSupportedPublicHost (demo_fqdn (domain config))
  validateDemoTtl (demo_ttl (domain config))
  validateAcmeBinding (acme config)
  validateTestSimulationAdminCredentials (aws_admin_for_test_simulation config)
  validatePublicEdgeDeployment (deployment config)

validatePublicEdgeDeployment :: DeploymentSection -> Either String ()
validatePublicEdgeDeployment deploymentSection = do
  validateBootstrapOverride
  validateAdvertisementMode
  validateReplicas
    "deployment.envoy_gateway_controller_replicas"
    (envoy_gateway_controller_replicas deploymentSection)
  validateReplicas
    "deployment.envoy_gateway_data_plane_replicas"
    (envoy_gateway_data_plane_replicas deploymentSection)
  validateReplicas "deployment.api_replicas" (api_replicas deploymentSection)
  validateReplicas "deployment.websocket_replicas" (websocket_replicas deploymentSection)
 where
  normalizedMode =
    fmap (Text.toLower . Text.strip) (public_edge_advertisement_mode deploymentSection)
  validateBootstrapOverride =
    validateOptionalIpAddressField
      "deployment.bootstrap_public_ip_override"
      (normalizeMaybeText (bootstrap_public_ip_override deploymentSection))
  validateAdvertisementMode =
    case normalizedMode of
      Nothing -> Right ()
      Just "l2" -> Right ()
      Just "bgp" ->
        case public_edge_bgp_peers deploymentSection of
          Just peers
            | not (null peers) ->
                mapM_ (uncurry validateBgpPeer) (zip [1 :: Int ..] peers)
          _ ->
            Left
              "deployment.public_edge_bgp_peers must contain at least one non-empty peer when deployment.public_edge_advertisement_mode is bgp"
      _ -> Left "deployment.public_edge_advertisement_mode must be l2 or bgp when set"

validateReplicas :: String -> Maybe Natural -> Either String ()
validateReplicas _ Nothing = Right ()
validateReplicas fieldName (Just value)
  | value >= 1 = Right ()
  | otherwise = Left (fieldName ++ " must be at least 1 when set")

requireNonEmpty :: String -> Text -> Either String ()
requireNonEmpty fieldName value =
  if Text.strip value == ""
    then Left (fieldName ++ " must not be empty")
    else Right ()

validateBgpPeer :: Int -> MetallbBgpPeer -> Either String ()
validateBgpPeer index peer = do
  requireNonEmpty fieldPrefixName (peer_name peer)
  requireNonEmpty fieldPrefixAddress (peer_address peer)
  validateOptionalIpAddressField fieldPrefixAddress (normalizeOptionalText (peer_address peer))
 where
  fieldPrefix = "deployment.public_edge_bgp_peers[" ++ show index ++ "]"
  fieldPrefixName = fieldPrefix ++ ".peer_name"
  fieldPrefixAddress = fieldPrefix ++ ".peer_address"

validateOptionalIpAddressField :: String -> Maybe Text -> Either String ()
validateOptionalIpAddressField _ Nothing = Right ()
validateOptionalIpAddressField fieldName (Just value)
  | isValidIpLiteral (Text.strip value) = Right ()
  | otherwise = Left (fieldName ++ " must be a valid IP address when set")

isValidIpLiteral :: Text -> Bool
isValidIpLiteral value =
  isValidIpv4Literal value || isValidIpv6Literal value

isValidIpv4Literal :: Text -> Bool
isValidIpv4Literal value =
  case Text.splitOn "." value of
    [firstOctet, secondOctet, thirdOctet, fourthOctet] ->
      all isValidIpv4Octet [firstOctet, secondOctet, thirdOctet, fourthOctet]
    _ -> False

isValidIpv4Octet :: Text -> Bool
isValidIpv4Octet octet =
  not (Text.null octet)
    && Text.all isDigit octet
    && case reads (Text.unpack octet) of
      [(value, "")] -> value >= (0 :: Int) && value <= 255
      _ -> False

isValidIpv6Literal :: Text -> Bool
isValidIpv6Literal value =
  case Text.splitOn "::" value of
    [groupsText] ->
      let groups = splitIpv6Groups groupsText
       in not (null groups) && isValidIpv6GroupList groups && ipv6GroupWidth groups == 8
    [leftText, rightText] ->
      let leftGroups = splitIpv6Groups leftText
          rightGroups = splitIpv6Groups rightText
          totalWidth = ipv6GroupWidth leftGroups + ipv6GroupWidth rightGroups
       in isValidIpv6GroupList leftGroups
            && isValidIpv6GroupList rightGroups
            && totalWidth < 8
    _ -> False

splitIpv6Groups :: Text -> [Text]
splitIpv6Groups value
  | Text.null value = []
  | otherwise = Text.splitOn ":" value

isValidIpv6GroupList :: [Text] -> Bool
isValidIpv6GroupList groups =
  and (zipWith validateGroup [0 :: Int ..] groups)
 where
  lastIndex = length groups - 1
  validateGroup index group
    | Text.null group = False
    | isValidIpv4Literal group = index == lastIndex
    | otherwise = isValidIpv6Hextet group

isValidIpv6Hextet :: Text -> Bool
isValidIpv6Hextet group =
  let lengthValue = Text.length group
   in lengthValue >= 1 && lengthValue <= 4 && Text.all isHexDigit group

ipv6GroupWidth :: [Text] -> Int
ipv6GroupWidth =
  sum . map (\group -> if isValidIpv4Literal group then 2 else 1)

validateSupportedPublicHost :: Text -> Either String ()
validateSupportedPublicHost value
  | normalized == "" = Left "domain.demo_fqdn must not be empty"
  | lowerValue /= Text.toLower supportedPublicHostname =
      Left
        ( "domain.demo_fqdn must be "
            ++ Text.unpack supportedPublicHostname
        )
  | otherwise = Right ()
 where
  normalized = Text.unpack (Text.strip value)
  lowerValue = Text.toLower (Text.strip value)

validateDemoTtl :: Natural -> Either String ()
validateDemoTtl ttl
  | ttl < 30 = Left "domain.demo_ttl must be between 30 and 86400"
  | ttl > 86400 = Left "domain.demo_ttl must be between 30 and 86400"
  | otherwise = Right ()

validateAcmeBinding :: AcmeSection -> Either String ()
validateAcmeBinding acmeSection
  | isZeroSslServer (server acmeSection)
      && (eab_key_id acmeSection == Nothing || eab_hmac_key acmeSection == Nothing) =
      Left "acme.eab_key_id and acme.eab_hmac_key are required for ZeroSSL ACME"
  | hasExactlyOne (eab_key_id acmeSection) (eab_hmac_key acmeSection) =
      Left "acme.eab_key_id and acme.eab_hmac_key must either both be set or both be empty"
  | otherwise = Right ()

validateTestSimulationAdminCredentials :: Credentials -> Either String ()
validateTestSimulationAdminCredentials adminSection =
  case ( normalizeOptionalText (access_key_id adminSection)
       , normalizeOptionalText (secret_access_key adminSection)
       , normalizeOptionalText (region adminSection)
       ) of
    (Nothing, Nothing, Nothing) -> Right ()
    (Just _, Just _, Just _) -> Right ()
    _ ->
      Left
        "aws_admin_for_test_simulation.access_key_id, aws_admin_for_test_simulation.secret_access_key, and aws_admin_for_test_simulation.region must either all be set or all be empty"

normalizeOptionalText :: Text -> Maybe Text
normalizeOptionalText value =
  if Text.strip value == ""
    then Nothing
    else Just value

normalizeMaybeText :: Maybe Text -> Maybe Text
normalizeMaybeText maybeValue = maybeValue >>= normalizeOptionalText

isZeroSslServer :: Text -> Bool
isZeroSslServer serverUrl =
  "https://acme.zerossl.com" `Text.isPrefixOf` Text.toLower serverUrl

hasExactlyOne :: Maybe a -> Maybe b -> Bool
hasExactlyOne left right =
  case (left, right) of
    (Just _, Nothing) -> True
    (Nothing, Just _) -> True
    _ -> False

renderSensitive :: Bool -> Text -> String
renderSensitive showSecrets value =
  renderMaybeText $
    if Text.strip value == ""
      then Nothing
      else Just (if showSecrets then value else maskSecret value)

renderSensitiveMaybe :: Bool -> Maybe Text -> String
renderSensitiveMaybe showSecrets maybeValue =
  renderMaybeText $
    fmap
      ( \value ->
          if showSecrets
            then value
            else maskSecret value
      )
      maybeValue

renderMaybeText :: Maybe Text -> String
renderMaybeText maybeValue =
  maybe "" renderText maybeValue

renderText :: Text -> String
renderText = Text.unpack

renderBool :: Bool -> String
renderBool value =
  map toLower (show value)

renderMaybeNatural :: Maybe Natural -> String
renderMaybeNatural maybeValue =
  maybe "" show maybeValue

renderBgpPeers :: Maybe [MetallbBgpPeer] -> String
renderBgpPeers maybePeers =
  case maybePeers of
    Nothing -> ""
    Just peers ->
      Text.unpack
        ( Text.intercalate
            ";"
            [ peer_name peer
              <> "@"
              <> peer_address peer
              <> ":peer_asn="
              <> Text.pack (show (peer_asn peer))
              <> ":my_asn="
              <> Text.pack (show (my_asn peer))
            | peer <- peers
            ]
        )

maskSecret :: Text -> Text
maskSecret value =
  if Text.length value > 4
    then "****" <> Text.takeEnd 4 value
    else "****"

defaultConfigFile :: ConfigFile
defaultConfigFile =
  ConfigFile
    { aws =
        Credentials
          { access_key_id = ""
          , secret_access_key = ""
          , session_token = Nothing
          , region = "us-east-1"
          }
    , aws_admin_for_test_simulation =
        Credentials
          { access_key_id = ""
          , secret_access_key = ""
          , session_token = Nothing
          , region = ""
          }
    , route53 = Route53Section {zone_id = ""}
    , domain =
        DomainSection
          { demo_fqdn = supportedPublicHostname
          , demo_ttl = 60
          }
    , acme =
        AcmeSection
          { email = ""
          , server = "https://acme-v02.api.letsencrypt.org/directory"
          , eab_key_id = Nothing
          , eab_hmac_key = Nothing
          }
    , deployment =
        DeploymentSection
          { dev_mode = True
          , bootstrap_public_ip_override = Nothing
          , pulumi_enable_dns_bootstrap = True
          , public_edge_advertisement_mode = Just "l2"
          , public_edge_bgp_peers = Nothing
          , envoy_gateway_controller_replicas = Just 1
          , envoy_gateway_data_plane_replicas = Just 1
          , api_replicas = Just 2
          , websocket_replicas = Just 2
          }
    , storage = StorageSection {manual_pv_host_root = ".data"}
    }

renderConfigDhall :: ConfigFile -> String
renderConfigDhall config =
  unlines
    [ "let Config = ./prodbox-config-types.dhall"
    , ""
    , "in  Config::{"
    , "    , aws = Config.default.aws // {"
    , "        , access_key_id = " ++ dhallText (access_key_id (aws config))
    , "        , secret_access_key = " ++ dhallText (secret_access_key (aws config))
    , "        , session_token = " ++ dhallOptionalText (session_token (aws config))
    , "        , region = " ++ dhallText (region (aws config))
    , "        }"
    , "    , aws_admin_for_test_simulation = Config.default.aws_admin_for_test_simulation // {"
    , "        , access_key_id = " ++ dhallText (access_key_id (aws_admin_for_test_simulation config))
    , "        , secret_access_key = "
        ++ dhallText (secret_access_key (aws_admin_for_test_simulation config))
    , "        , session_token = "
        ++ dhallOptionalText (session_token (aws_admin_for_test_simulation config))
    , "        , region = " ++ dhallText (region (aws_admin_for_test_simulation config))
    , "        }"
    , "    , route53 = { zone_id = " ++ dhallText (zone_id (route53 config)) ++ " }"
    , "    , domain = Config.default.domain // {"
    , "        , demo_fqdn = " ++ dhallText (demo_fqdn (domain config))
    , "        , demo_ttl = " ++ show (demo_ttl (domain config))
    , "        }"
    , "    , acme = Config.default.acme // {"
    , "        , email = " ++ dhallText (email (acme config))
    , "        , server = " ++ dhallText (server (acme config))
    , "        , eab_key_id = " ++ dhallOptionalText (eab_key_id (acme config))
    , "        , eab_hmac_key = " ++ dhallOptionalText (eab_hmac_key (acme config))
    , "        }"
    , "    , deployment = Config.default.deployment // {"
    , "        , dev_mode = " ++ dhallBool (dev_mode (deployment config))
    , "        , bootstrap_public_ip_override = "
        ++ dhallOptionalText (bootstrap_public_ip_override (deployment config))
    , "        , pulumi_enable_dns_bootstrap = "
        ++ dhallBool (pulumi_enable_dns_bootstrap (deployment config))
    , "        , public_edge_advertisement_mode = "
        ++ dhallOptionalText (public_edge_advertisement_mode (deployment config))
    , "        , public_edge_bgp_peers = "
        ++ dhallOptionalBgpPeers (public_edge_bgp_peers (deployment config))
    , "        , envoy_gateway_controller_replicas = "
        ++ dhallOptionalNatural (envoy_gateway_controller_replicas (deployment config))
    , "        , envoy_gateway_data_plane_replicas = "
        ++ dhallOptionalNatural (envoy_gateway_data_plane_replicas (deployment config))
    , "        , api_replicas = " ++ dhallOptionalNatural (api_replicas (deployment config))
    , "        , websocket_replicas = " ++ dhallOptionalNatural (websocket_replicas (deployment config))
    , "        }"
    , "    , storage = Config.default.storage // {"
    , "        , manual_pv_host_root = " ++ dhallText (manual_pv_host_root (storage config))
    , "        }"
    , "    }"
    , ""
    ]

dhallText :: Text -> String
dhallText = show . Text.unpack

dhallOptionalText :: Maybe Text -> String
dhallOptionalText maybeValue =
  case maybeValue of
    Nothing -> "None Text"
    Just value -> "Some " ++ dhallText value

dhallOptionalNatural :: Maybe Natural -> String
dhallOptionalNatural maybeValue =
  case maybeValue of
    Nothing -> "None Natural"
    Just value -> "Some " ++ show value

dhallOptionalBgpPeers :: Maybe [MetallbBgpPeer] -> String
dhallOptionalBgpPeers maybePeers =
  case maybePeers of
    Nothing ->
      "None (List { peer_name : Text, peer_address : Text, peer_asn : Natural, my_asn : Natural, ebgp_multi_hop : Optional Bool })"
    Just [] ->
      "Some ([] : List { peer_name : Text, peer_address : Text, peer_asn : Natural, my_asn : Natural, ebgp_multi_hop : Optional Bool })"
    Just peers ->
      "Some [ "
        ++ foldr1
          (\left right -> left ++ ", " ++ right)
          (map dhallBgpPeer peers)
        ++ " ]"
 where
  dhallBgpPeer peer =
    "{ peer_name = "
      ++ dhallText (peer_name peer)
      ++ ", peer_address = "
      ++ dhallText (peer_address peer)
      ++ ", peer_asn = "
      ++ show (peer_asn peer)
      ++ ", my_asn = "
      ++ show (my_asn peer)
      ++ ", ebgp_multi_hop = "
      ++ dhallOptionalBool (ebgp_multi_hop peer)
      ++ " }"

dhallOptionalBool :: Maybe Bool -> String
dhallOptionalBool maybeValue =
  case maybeValue of
    Nothing -> "None Bool"
    Just value -> "Some " ++ dhallBool value

dhallBool :: Bool -> String
dhallBool True = "True"
dhallBool False = "False"

missingConfigMessage :: FilePath -> String
missingConfigMessage configPath =
  unlines
    [ "Missing required repository config `" ++ configPath ++ "`."
    , "Run `./.build/prodbox config setup` from the repository root to create it, then rerun the command."
    ]
