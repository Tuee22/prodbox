{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Settings
    ( AcmeSection (..),
      ConfigFile (..),
      Credentials (..),
      DeploymentSection (..),
      DomainSection (..),
      Route53Section (..),
      StorageSection (..),
      ValidatedSettings (..),
      defaultConfigFile,
      loadConfigFile,
      materializeConfigJson,
      renderConfigDhall,
      renderSettingsDisplay,
      validateAndLoadSettings,
    )
where

import Control.Exception
    ( SomeException,
      displayException,
      try,
    )
import Data.Aeson
    ( Options,
      ToJSON (toJSON),
      defaultOptions,
      genericToJSON,
      omitNothingFields,
    )
import Data.Aeson.Encode.Pretty
    ( Config (confIndent),
      Indent (Spaces),
      defConfig,
      encodePretty',
    )
import qualified Data.ByteString.Lazy as BL
import Data.Char (toLower)
import qualified Data.Text as Text
import Data.Text (Text)
import Dhall (FromDhall, auto, inputFile)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Repo
    ( ConfigPaths (..),
      canonicalConfigPaths,
    )
import System.Directory
    ( doesFileExist,
      getModificationTime,
      makeAbsolute,
    )
import System.FilePath ((</>))

data Credentials = Credentials
    { access_key_id :: Text,
      secret_access_key :: Text,
      session_token :: Maybe Text,
      region :: Text
    }
    deriving (Eq, Show, Generic, FromDhall)

instance ToJSON Credentials where
    toJSON = genericToJSON jsonOptions

data Route53Section = Route53Section
    { zone_id :: Text
    }
    deriving (Eq, Show, Generic, FromDhall)

instance ToJSON Route53Section where
    toJSON = genericToJSON jsonOptions

data DomainSection = DomainSection
    { demo_fqdn :: Text,
      demo_ttl :: Natural,
      vscode_fqdn :: Maybe Text
    }
    deriving (Eq, Show, Generic, FromDhall)

instance ToJSON DomainSection where
    toJSON = genericToJSON jsonOptions

data AcmeSection = AcmeSection
    { email :: Text,
      server :: Text,
      eab_key_id :: Maybe Text,
      eab_hmac_key :: Maybe Text
    }
    deriving (Eq, Show, Generic, FromDhall)

instance ToJSON AcmeSection where
    toJSON = genericToJSON jsonOptions

data DeploymentSection = DeploymentSection
    { dev_mode :: Bool,
      bootstrap_public_ip_override :: Maybe Text,
      pulumi_enable_dns_bootstrap :: Bool
    }
    deriving (Eq, Show, Generic, FromDhall)

instance ToJSON DeploymentSection where
    toJSON = genericToJSON jsonOptions

data StorageSection = StorageSection
    { manual_pv_host_root :: Text
    }
    deriving (Eq, Show, Generic, FromDhall)

instance ToJSON StorageSection where
    toJSON = genericToJSON jsonOptions

data ConfigFile = ConfigFile
    { aws :: Credentials,
      aws_admin :: Credentials,
      route53 :: Route53Section,
      domain :: DomainSection,
      acme :: AcmeSection,
      deployment :: DeploymentSection,
      storage :: StorageSection
    }
    deriving (Eq, Show, Generic, FromDhall)

instance ToJSON ConfigFile where
    toJSON = genericToJSON jsonOptions

data ValidatedSettings = ValidatedSettings
    { validatedConfig :: ConfigFile,
      resolvedManualPvHostRoot :: FilePath
    }
    deriving (Eq, Show)

validateAndLoadSettings :: FilePath -> IO (Either String ValidatedSettings)
validateAndLoadSettings repoRoot = do
    configResult <- loadConfigFile repoRoot
    case configResult of
        Left err -> pure (Left err)
        Right config -> do
            validatedResult <- validateConfig repoRoot config
            case validatedResult of
                Left err -> pure (Left err)
                Right settings -> do
                    materializeResult <- ensureMaterializedConfigJson repoRoot config
                    case materializeResult of
                        Left err -> pure (Left err)
                        Right () -> pure (Right settings)

materializeConfigJson :: FilePath -> IO (Either String ())
materializeConfigJson repoRoot = do
    configResult <- loadConfigFile repoRoot
    case configResult of
        Left err -> pure (Left err)
        Right config -> writeMaterializedConfig repoRoot config

renderSettingsDisplay :: Bool -> ValidatedSettings -> String
renderSettingsDisplay showSecrets settings =
    unlines
        [ "aws.region=" ++ renderText (region (aws config)),
          "aws.access_key_id=" ++ renderSensitive showSecrets (access_key_id (aws config)),
          "aws.secret_access_key=" ++ renderSensitive showSecrets (secret_access_key (aws config)),
          "aws.session_token=" ++ renderSensitiveMaybe showSecrets (session_token (aws config)),
          "aws_admin.access_key_id=" ++ renderSensitiveMaybe showSecrets (normalizeOptionalText (access_key_id (aws_admin config))),
          "aws_admin.secret_access_key=" ++ renderSensitiveMaybe showSecrets (normalizeOptionalText (secret_access_key (aws_admin config))),
          "aws_admin.session_token=" ++ renderSensitiveMaybe showSecrets (normalizeMaybeText (session_token (aws_admin config))),
          "aws_admin.region=" ++ renderMaybeText (normalizeOptionalText (region (aws_admin config))),
          "route53.zone_id=" ++ renderText (zone_id (route53 config)),
          "domain.demo_fqdn=" ++ renderText (demo_fqdn (domain config)),
          "domain.demo_ttl=" ++ show (demo_ttl (domain config)),
          "domain.vscode_fqdn=" ++ renderMaybeText (vscode_fqdn (domain config)),
          "acme.email=" ++ renderSensitive showSecrets (email (acme config)),
          "acme.server=" ++ renderText (server (acme config)),
          "acme.eab_key_id=" ++ renderMaybeText (eab_key_id (acme config)),
          "acme.eab_hmac_key=" ++ renderSensitiveMaybe showSecrets (eab_hmac_key (acme config)),
          "deployment.dev_mode=" ++ renderBool (dev_mode (deployment config)),
          "deployment.bootstrap_public_ip_override=" ++ renderMaybeText (bootstrap_public_ip_override (deployment config)),
          "deployment.pulumi_enable_dns_bootstrap=" ++ renderBool (pulumi_enable_dns_bootstrap (deployment config)),
          "storage.manual_pv_host_root=" ++ resolvedManualPvHostRoot settings
        ]
  where
    config = validatedConfig settings

loadConfigFile :: FilePath -> IO (Either String ConfigFile)
loadConfigFile repoRoot = do
    let paths = canonicalConfigPaths repoRoot
    decoded <- try (inputFile auto (configDhallPath paths)) :: IO (Either SomeException ConfigFile)
    pure $ case decoded of
        Left err -> Left (displayException err)
        Right config -> Right config

validateConfig :: FilePath -> ConfigFile -> IO (Either String ValidatedSettings)
validateConfig repoRoot config = do
    resolvedManualRoot <- makeAbsolute (repoRoot </> Text.unpack (manual_pv_host_root (storage config)))
    pure $ do
        requireNonEmpty "aws.access_key_id" (access_key_id (aws config))
        requireNonEmpty "aws.secret_access_key" (secret_access_key (aws config))
        requireNonEmpty "route53.zone_id" (zone_id (route53 config))
        requireNonEmpty "acme.email" (email (acme config))
        validateDemoTtl (demo_ttl (domain config))
        validateAcmeBinding (acme config)
        validateAdminCredentials (aws_admin config)
        pure
            ValidatedSettings
                { validatedConfig = config,
                  resolvedManualPvHostRoot = resolvedManualRoot
                }

writeMaterializedConfig :: FilePath -> ConfigFile -> IO (Either String ())
writeMaterializedConfig repoRoot config = do
    let paths = canonicalConfigPaths repoRoot
        encoded = encodePretty' jsonPrettyConfig config
    writeResult <- try (BL.writeFile (configJsonPath paths) encoded) :: IO (Either SomeException ())
    pure $ case writeResult of
        Left err -> Left (displayException err)
        Right () -> Right ()

ensureMaterializedConfigJson :: FilePath -> ConfigFile -> IO (Either String ())
ensureMaterializedConfigJson repoRoot config = do
    let paths = canonicalConfigPaths repoRoot
    shouldWrite <- configJsonNeedsRefresh paths
    if shouldWrite then writeMaterializedConfig repoRoot config else pure (Right ())

configJsonNeedsRefresh :: ConfigPaths -> IO Bool
configJsonNeedsRefresh paths = do
    jsonExists <- doesFileExist (configJsonPath paths)
    if not jsonExists
        then pure True
        else do
            jsonTime <- getModificationTime (configJsonPath paths)
            dhallExists <- doesFileExist (configDhallPath paths)
            schemaExists <- doesFileExist (configSchemaPath paths)
            dhallIsNewer <-
                if dhallExists
                    then (> jsonTime) <$> getModificationTime (configDhallPath paths)
                    else pure False
            schemaIsNewer <-
                if schemaExists
                    then (> jsonTime) <$> getModificationTime (configSchemaPath paths)
                    else pure False
            pure (dhallIsNewer || schemaIsNewer)

requireNonEmpty :: String -> Text -> Either String ()
requireNonEmpty fieldName value =
    if Text.strip value == ""
        then Left (fieldName ++ " must not be empty")
        else Right ()

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

validateAdminCredentials :: Credentials -> Either String ()
validateAdminCredentials adminSection =
    case
        ( normalizeOptionalText (access_key_id adminSection),
          normalizeOptionalText (secret_access_key adminSection),
          normalizeOptionalText (region adminSection)
        ) of
        (Nothing, Nothing, Nothing) -> Right ()
        (Just _, Just _, Just _) -> Right ()
        _ ->
            Left
                "aws_admin.access_key_id, aws_admin.secret_access_key, and aws_admin.region must either all be set or all be empty"

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
            (\value ->
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
                { access_key_id = "",
                  secret_access_key = "",
                  session_token = Nothing,
                  region = "us-east-1"
                },
          aws_admin =
            Credentials
                { access_key_id = "",
                  secret_access_key = "",
                  session_token = Nothing,
                  region = ""
                },
          route53 = Route53Section{zone_id = ""},
          domain =
            DomainSection
                { demo_fqdn = "demo.example.com",
                  demo_ttl = 60,
                  vscode_fqdn = Nothing
                },
          acme =
            AcmeSection
                { email = "",
                  server = "https://acme-v02.api.letsencrypt.org/directory",
                  eab_key_id = Nothing,
                  eab_hmac_key = Nothing
                },
          deployment =
            DeploymentSection
                { dev_mode = True,
                  bootstrap_public_ip_override = Nothing,
                  pulumi_enable_dns_bootstrap = True
                },
          storage = StorageSection{manual_pv_host_root = ".data"}
        }

renderConfigDhall :: ConfigFile -> String
renderConfigDhall config =
    unlines
        [ "let Config = ./prodbox-config-types.dhall",
          "",
          "in  Config::{",
          "    , aws = Config.default.aws // {",
          "        , access_key_id = " ++ dhallText (access_key_id (aws config)),
          "        , secret_access_key = " ++ dhallText (secret_access_key (aws config)),
          "        , session_token = " ++ dhallOptionalText (session_token (aws config)),
          "        , region = " ++ dhallText (region (aws config)),
          "        }",
          "    , aws_admin = Config.default.aws_admin // {",
          "        , access_key_id = " ++ dhallText (access_key_id (aws_admin config)),
          "        , secret_access_key = " ++ dhallText (secret_access_key (aws_admin config)),
          "        , session_token = " ++ dhallOptionalText (session_token (aws_admin config)),
          "        , region = " ++ dhallText (region (aws_admin config)),
          "        }",
          "    , route53 = { zone_id = " ++ dhallText (zone_id (route53 config)) ++ " }",
          "    , domain = Config.default.domain // {",
          "        , demo_fqdn = " ++ dhallText (demo_fqdn (domain config)),
          "        , demo_ttl = " ++ show (demo_ttl (domain config)),
          "        , vscode_fqdn = " ++ dhallOptionalText (vscode_fqdn (domain config)),
          "        }",
          "    , acme = Config.default.acme // {",
          "        , email = " ++ dhallText (email (acme config)),
          "        , server = " ++ dhallText (server (acme config)),
          "        , eab_key_id = " ++ dhallOptionalText (eab_key_id (acme config)),
          "        , eab_hmac_key = " ++ dhallOptionalText (eab_hmac_key (acme config)),
          "        }",
          "    , deployment = Config.default.deployment // {",
          "        , dev_mode = " ++ dhallBool (dev_mode (deployment config)),
          "        , bootstrap_public_ip_override = " ++ dhallOptionalText (bootstrap_public_ip_override (deployment config)),
          "        , pulumi_enable_dns_bootstrap = " ++ dhallBool (pulumi_enable_dns_bootstrap (deployment config)),
          "        }",
          "    , storage = Config.default.storage // {",
          "        , manual_pv_host_root = " ++ dhallText (manual_pv_host_root (storage config)),
          "        }",
          "    }",
          ""
        ]

dhallText :: Text -> String
dhallText = show . Text.unpack

dhallOptionalText :: Maybe Text -> String
dhallOptionalText maybeValue =
    case maybeValue of
        Nothing -> "None Text"
        Just value -> "Some " ++ dhallText value

dhallBool :: Bool -> String
dhallBool True = "True"
dhallBool False = "False"

jsonOptions :: Options
jsonOptions = defaultOptions{omitNothingFields = True}

jsonPrettyConfig :: Config
jsonPrettyConfig = defConfig{confIndent = Spaces 2}
