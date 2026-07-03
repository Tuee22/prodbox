{-# LANGUAGE DuplicateRecordFields #-}

module Prodbox.CLI.Spec
  ( ArgumentSpec (..)
  , CommandSpec (..)
  , Example (..)
  , OptionSpec (..)
  , awsTeardownPolicyFromFlags
  , commandRequestParser
  , commandRegistry
  , findCommandSpec
  , leafCommandPaths
  , outputOptionsParser
  )
where

import Control.Applicative ((<|>))
import Data.List (find)
import Options.Applicative
  ( Parser
  , ReadM
  , auto
  , command
  , eitherReader
  , flag'
  , help
  , hsubparser
  , info
  , long
  , many
  , metavar
  , option
  , optional
  , progDesc
  , short
  , some
  , strArgument
  , strOption
  , switch
  , value
  )
import Prodbox.CLI.Command
  ( AwsCommand (..)
  , AwsTeardownFlags (..)
  , ChartsCommand (..)
  , CommandListingFormat (..)
  , CommandRequest (..)
  , ConfigCommand (..)
  , CoverageFlags (..)
  , DaemonLaunchOptions (..)
  , DaemonStatusOptions (..)
  , DnsCommand (..)
  , DocsCommand (..)
  , EdgeCommand (..)
  , FederationRegisterOptions (..)
  , GatewayCommand (..)
  , HostCommand (..)
  , IntegrationSuite (..)
  , K8sCommand (..)
  , LintCommand (..)
  , NativeCommand (..)
  , NukeOptions (..)
  , PerRunPruneTarget (..)
  , PlanOptions (..)
  , PolicyTier (..)
  , PulumiCommand (..)
  , PulumiResiduePolicy (..)
  , Rke2Command (..)
  , Rke2DeleteFlags (..)
  , TestCommand (..)
  , TestScope (..)
  , UsersCommand (..)
  , UsersListStatus (..)
  , VaultCommand (..)
  , WorkloadCommand (..)
  , WorkloadOptions (..)
  )
import Prodbox.CLI.Output
  ( ColorMode (..)
  , OutputFormat (..)
  , OutputOptions (..)
  )
import Prodbox.K8s (defaultInfrastructureNamespaces)
import Prodbox.Substrate
  ( Substrate
  , defaultSubstrate
  , parseSubstrate
  )

data Example = Example
  { exampleCommand :: [String]
  , exampleDescription :: String
  }
  deriving (Eq, Show)

data OptionSpec = OptionSpec
  { longName :: String
  , shortName :: Maybe Char
  , optionMetavar :: Maybe String
  , description :: String
  , required :: Bool
  }
  deriving (Eq, Show)

-- | A positional argument a leaf command accepts. This is the
-- documentation source of truth for positionals the flat 'OptionSpec'
-- list cannot express (e.g. @charts status \<CHART\>@,
-- @gateway config-gen \<OUTPUT_PATH\>@, @help \<COMMAND_PATH...\>@). The
-- parser still derives positional handling from the
-- 'optparse-applicative' bindings in 'parserForPath'; this spec field
-- exists so the generated docs can render an "Arguments" column without
-- re-deriving it from the parser.
data ArgumentSpec = ArgumentSpec
  { argumentName :: String
  , argumentMetavar :: String
  , argumentDescription :: String
  , argumentOptional :: Bool
  , argumentRepeatable :: Bool
  }
  deriving (Eq, Show)

data CommandSpec = CommandSpec
  { name :: String
  , summary :: String
  , description :: String
  , children :: [CommandSpec]
  , arguments :: [ArgumentSpec]
  , options :: [OptionSpec]
  , examples :: [Example]
  }
  deriving (Eq, Show)

commandRegistry :: CommandSpec
commandRegistry =
  CommandSpec
    { name = "prodbox"
    , summary = "Home Kubernetes operator"
    , description = "Typed command registry for the supported prodbox command surface."
    , children =
        [ awsGroup
        , chartsGroup
        , clusterGroup
        , commandsLeaf
        , configGroup
        , devGroup
        , dnsGroup
        , edgeGroup
        , gatewayGroup
        , helpLeaf
        , hostGroup
        , nukeLeaf
        , testGroupSpec
        , usersGroup
        , vaultGroup
        , workloadGroup
        ]
    , arguments = []
    , options =
        [ flagOption "verbose" (Just 'v') Nothing "Enable verbose output"
        , flagOption "version" Nothing Nothing "Show version"
        ]
    , examples =
        [ example ["config", "validate"] "Validate the repository Dhall config."
        , example ["test", "all"] "Run the full test surface."
        ]
    }

findCommandSpec :: [String] -> Maybe CommandSpec
findCommandSpec [] = Just commandRegistry
findCommandSpec path = go commandRegistry path
 where
  go spec [] = Just spec
  go spec (segment : remaining) = do
    child <- find ((== segment) . name) (children spec)
    go child remaining

leafCommandPaths :: [[String]]
leafCommandPaths = gather [] commandRegistry
 where
  gather prefix spec =
    case children spec of
      [] -> [prefix ++ [name spec] | name spec /= "prodbox"]
      nested ->
        concatMap (gather (prefix ++ nextPrefix)) nested
       where
        nextPrefix = [name spec | name spec /= "prodbox"]

commandRequestParser :: Parser CommandRequest
commandRequestParser = renderCommandRequestParser [] commandRegistry

renderCommandRequestParser :: [String] -> CommandSpec -> Parser CommandRequest
renderCommandRequestParser prefix spec =
  case children spec of
    [] ->
      case parserForPath currentPath of
        Just parser -> parser
        Nothing ->
          error ("Missing parser binding for command path: prodbox " ++ unwords currentPath)
    nested ->
      hsubparser
        ( mconcat
            [ command
                (name child)
                (info (renderCommandRequestParser currentPath child) (progDesc (summary child)))
            | child <- nested
            ]
        )
 where
  currentPath =
    if name spec == "prodbox"
      then prefix
      else prefix ++ [name spec]

parserForPath :: [String] -> Maybe (Parser CommandRequest)
parserForPath path =
  case path of
    ["aws", "policy"] ->
      Just $
        fmap
          (RunNative . NativeAws . AwsPolicy)
          (tierOptionParser PolicyCore "Operational IAM policy tier to render")
    ["aws", "setup"] ->
      Just $
        fmap
          (\(policyTier, planOptions') -> RunNative (NativeAws (AwsSetup policyTier planOptions')))
          ((,) <$> tierOptionParser PolicyFull "Operational IAM policy tier to provision" <*> planOptionsParser)
    ["aws", "teardown"] ->
      Just $
        fmap
          ( \(planOptions', flags) ->
              RunNative (NativeAws (AwsTeardown planOptions' flags))
          )
          ((,) <$> planOptionsParser <*> awsTeardownFlagsParser)
    ["aws", "quotas", "check"] -> Just (pure (RunNative (NativeAws AwsCheckQuotas)))
    ["aws", "quotas", "request"] ->
      Just $
        fmap
          (RunNative . NativeAws . AwsRequestQuotas)
          (tierOptionParser PolicyFull "Quota target tier to request")
    ["aws", "ebs", "reap-test"] ->
      Just $
        fmap
          (RunNative . NativeAws . AwsReapTestEbs)
          (yesSwitchParser "Confirm deletion of test-scoped EBS volumes")
    ["charts", "list"] -> Just (pure (RunNative (NativeCharts ChartsList)))
    ["charts", "status"] ->
      Just (fmap (RunNative . NativeCharts . ChartsStatus) (strArgument (metavar "CHART")))
    ["charts", "reconcile"] ->
      Just $
        fmap
          ( \(chartName, substrate, options') ->
              RunNative (NativeCharts (ChartsDeploy chartName substrate options'))
          )
          ( (,,)
              <$> strArgument (metavar "CHART")
              <*> substrateOptionParser
              <*> planOptionsParser
          )
    ["charts", "delete"] ->
      Just $
        ( \chartName substrate confirmed options' ->
            RunNative (NativeCharts (ChartsDelete chartName substrate confirmed options'))
        )
          <$> strArgument (metavar "CHART")
          <*> substrateOptionParser
          <*> yesSwitchParser "Skip confirmation prompt"
          <*> planOptionsParser
    ["dev", "check"] -> Just (pure (RunNative NativeCheckCode))
    ["commands"] ->
      Just $
        commandsTreeParser
          <|> commandsJsonParser
          <|> pure (ShowCommands CommandsPlain)
    ["config", "setup"] ->
      Just (fmap (RunNative . NativeConfig . ConfigSetup) planOptionsParser)
    ["config", "show"] ->
      Just $
        fmap
          (\showSecrets -> RunNative (NativeConfig (ConfigShow showSecrets)))
          ( switch
              ( long "show-secrets"
                  <> help "Show full secret values"
              )
          )
    ["config", "validate"] -> Just (pure (RunNative (NativeConfig ConfigValidate)))
    ["config", "schema"] -> Just (pure (RunNative (NativeConfig ConfigSchema)))
    ["config", "generate"] -> Just (pure (RunNative (NativeConfig ConfigGenerate)))
    ["vault", "status"] -> Just (pure (RunNative (NativeVault VaultStatus)))
    ["vault", "init"] -> Just (pure (RunNative (NativeVault VaultInit)))
    ["vault", "unseal"] -> Just (pure (RunNative (NativeVault VaultUnseal)))
    ["vault", "seal"] -> Just (pure (RunNative (NativeVault VaultSeal)))
    ["vault", "reconcile"] -> Just (pure (RunNative (NativeVault VaultReconcile)))
    ["vault", "rotate-unlock-bundle"] ->
      Just (pure (RunNative (NativeVault VaultRotateUnlockBundle)))
    ["vault", "rotate-transit-key"] ->
      Just (fmap (RunNative . NativeVault . VaultRotateTransitKey) (strArgument (metavar "KEY")))
    ["vault", "pki", "status"] -> Just (pure (RunNative (NativeVault VaultPkiStatus)))
    ["vault", "pki", "issue-test-cert"] ->
      Just (pure (RunNative (NativeVault VaultPkiIssueTestCert)))
    ["dns", "check"] -> Just (pure (RunNative (NativeDns DnsCheck)))
    ["dev", "docs", "check"] -> Just (pure (RunNative (NativeDocs DocsCheck)))
    ["dev", "docs", "generate"] -> Just (pure (RunNative (NativeDocs DocsGenerate)))
    ["gateway", "start"] ->
      Just (fmap (RunNative . NativeGateway . GatewayDaemonCommand) daemonLaunchOptionsParser)
    ["gateway", "status"] ->
      Just (fmap (RunNative . NativeGateway . GatewayStatusCommand) daemonStatusOptionsParser)
    ["gateway", "config-gen"] ->
      Just $
        fmap
          (\(outputPath, nodeId) -> RunNative (NativeGateway (GatewayConfigGen outputPath nodeId)))
          ( (,)
              <$> strArgument (metavar "OUTPUT_PATH")
              <*> strOption
                ( long "node-id"
                    <> metavar "NODE_ID"
                    <> help "Node ID for the generated config"
                )
          )
    ["help"] -> Just (ShowHelp <$> some (strArgument (metavar "COMMAND_PATH")))
    ["host", "ensure-tools"] -> Just (pure (RunNative (NativeHost HostEnsureTools)))
    ["host", "check-ports"] -> Just (pure (RunNative (NativeHost HostCheckPorts)))
    ["host", "info"] -> Just (pure (RunNative (NativeHost HostInfo)))
    ["host", "firewall", "gateway-restrict"] ->
      Just (RunNative . NativeHost . HostFirewallGatewayRestrict <$> gatewayNodePortParser)
    ["host", "firewall", "gateway-unrestrict"] ->
      Just (RunNative . NativeHost . HostFirewallGatewayUnrestrict <$> gatewayNodePortParser)
    ["edge", "status"] ->
      Just (fmap (RunNative . NativeHost . HostPublicEdge) substrateOptionParser)
    ["edge", "reconcile"] ->
      Just (fmap (RunNative . NativeEdge . EdgeReconcile) planOptionsParser)
    ["cluster", "health"] -> Just (pure (RunNative (NativeK8s K8sHealth)))
    ["cluster", "wait"] ->
      Just $
        fmap
          ( \(timeoutSeconds, namespaces) ->
              RunNative (NativeK8s (K8sWait (maybe 300 id timeoutSeconds) (defaultNamespaces namespaces)))
          )
          ( (,)
              <$> optional
                ( option
                    auto
                    ( long "timeout"
                        <> short 't'
                        <> metavar "INTEGER"
                        <> help "Timeout in seconds"
                    )
                )
              <*> manyStringsOption "namespace" 'n' "Namespace to wait for"
          )
    ["cluster", "workload-logs"] ->
      Just $
        fmap
          ( \(namespaces, tailLines) ->
              RunNative (NativeK8s (K8sLogs (defaultNamespaces namespaces) (maybe 10 id tailLines)))
          )
          ( (,)
              <$> manyStringsOption "namespace" 'n' "Namespace to get logs from"
              <*> optional
                ( option
                    auto
                    ( long "tail"
                        <> metavar "INTEGER"
                        <> help "Number of log lines per container"
                    )
                )
          )
    ["dev", "lint", "all"] -> Just (pure (RunNative (NativeLint LintAll)))
    ["dev", "lint", "files"] -> Just (fmap (RunNative . NativeLint . LintFiles) writeSwitchParser)
    ["dev", "lint", "docs"] -> Just (fmap (RunNative . NativeLint . LintDocs) writeSwitchParser)
    ["dev", "lint", "haskell"] -> Just (fmap (RunNative . NativeLint . LintHaskell) writeSwitchParser)
    ["dev", "lint", "chart"] -> Just (pure (RunNative (NativeLint LintChart)))
    ["aws", "stack", "eks", "reconcile"] ->
      Just (fmap (RunNative . NativePulumi . PulumiEksResources) planOptionsParser)
    ["aws", "stack", "eks", "destroy"] ->
      Just $
        fmap
          (\(confirmed, planOptions') -> RunNative (NativePulumi (PulumiEksDestroy confirmed planOptions')))
          ((,) <$> yesSwitchParser "Skip confirmation prompts" <*> planOptionsParser)
    ["aws", "stack", "test", "reconcile"] ->
      Just (fmap (RunNative . NativePulumi . PulumiTestResources) planOptionsParser)
    ["aws", "stack", "test", "destroy"] ->
      Just $
        fmap
          (\(confirmed, planOptions') -> RunNative (NativePulumi (PulumiTestDestroy confirmed planOptions')))
          ((,) <$> yesSwitchParser "Skip confirmation prompts" <*> planOptionsParser)
    ["aws", "stack", "aws-subzone", "reconcile"] ->
      Just (fmap (RunNative . NativePulumi . PulumiAwsSubzoneResources) planOptionsParser)
    ["aws", "stack", "aws-subzone", "destroy"] ->
      Just $
        fmap
          ( \(confirmed, planOptions') ->
              RunNative (NativePulumi (PulumiAwsSubzoneDestroy confirmed planOptions'))
          )
          ((,) <$> yesSwitchParser "Skip confirmation prompts" <*> planOptionsParser)
    ["aws", "stack", "aws-ses", "reconcile"] ->
      Just (fmap (RunNative . NativePulumi . PulumiAwsSesResources) planOptionsParser)
    ["aws", "stack", "aws-ses", "destroy"] ->
      Just $
        fmap
          ( \(confirmed, planOptions') ->
              RunNative (NativePulumi (PulumiAwsSesDestroy confirmed planOptions'))
          )
          ((,) <$> yesSwitchParser "Skip confirmation prompts" <*> planOptionsParser)
    ["aws", "stack", "aws-ses", "migrate-backend"] ->
      Just (fmap (RunNative . NativePulumi . PulumiAwsSesMigrateBackend) planOptionsParser)
    ["aws", "stack", "eks", "prune-corrupt-checkpoint"] ->
      Just
        (fmap (prunePerRunCheckpointCommand PrunePerRunEks) (yesSwitchParser "Skip confirmation prompts"))
    ["aws", "stack", "test", "prune-corrupt-checkpoint"] ->
      Just
        (fmap (prunePerRunCheckpointCommand PrunePerRunTest) (yesSwitchParser "Skip confirmation prompts"))
    ["aws", "stack", "aws-subzone", "prune-corrupt-checkpoint"] ->
      Just
        (fmap (prunePerRunCheckpointCommand PrunePerRunSubzone) (yesSwitchParser "Skip confirmation prompts"))
    ["users", "invite"] ->
      Just $
        ( \email maybeRole planOptions' ->
            RunNative (NativeUsers (UsersInvite email maybeRole planOptions'))
        )
          <$> strArgument (metavar "EMAIL")
          <*> optional
            ( strOption
                ( long "role"
                    <> metavar "ROLE"
                    <> help "Operator-defined role to assign on invite"
                )
            )
          <*> planOptionsParser
    ["users", "list"] ->
      Just $
        fmap
          (RunNative . NativeUsers . UsersList)
          ( flag'
              UsersVerified
              ( long "status"
                  <> short 's'
                  <> help "Filter by status: verified (omit flag for all users)"
              )
              <|> flag' UsersUnverified (long "status-unverified" <> help "Filter by status: unverified")
              <|> pure UsersAll
          )
    ["users", "revoke"] ->
      Just $
        ( \ident hardDelete planOptions' ->
            RunNative (NativeUsers (UsersRevoke ident hardDelete planOptions'))
        )
          <$> strArgument (metavar "EMAIL_OR_USER_ID")
          <*> switch (long "delete" <> help "Fully delete the user instead of disabling")
          <*> planOptionsParser
    ["cluster", "status"] -> Just (pure (RunNative (NativeRke2 Rke2Status)))
    ["cluster", "start"] -> Just (pure (RunNative (NativeRke2 Rke2Start)))
    ["cluster", "stop"] -> Just (pure (RunNative (NativeRke2 Rke2Stop)))
    ["cluster", "restart"] -> Just (pure (RunNative (NativeRke2 Rke2Restart)))
    ["cluster", "reconcile"] ->
      Just
        ( fmap
            (RunNative . NativeRke2)
            (Rke2Reconcile <$> planOptionsParser <*> withPublicEdgeSwitch)
        )
    ["cluster", "delete"] ->
      Just (rke2DeleteParser <$> rke2DeleteFlagsParser <*> planOptionsParser)
    ["cluster", "federation", "register"] ->
      Just $
        (\childClusterId options' -> RunNative (NativeRke2 (Rke2FederationRegister childClusterId options')))
          <$> strArgument (metavar "CHILD")
          <*> federationRegisterOptionsParser
    ["cluster", "logs"] ->
      Just $
        fmap
          (RunNative . NativeRke2 . Rke2Logs)
          ( optional
              ( option
                  auto
                  ( long "lines"
                      <> short 'n'
                      <> metavar "INTEGER"
                      <> help "Number of log lines to show"
                  )
              )
          )
    ["test", "init"] -> Just testInitParser
    ["test", "run"] -> Just testRunParser
    ["test", "all"] -> Just (withCoverage TestAll)
    ["test", "lint"] ->
      Just
        ( pure
            (RunNative (NativeTest (TestCommand TestLint (CoverageFlags False Nothing) defaultSubstrate)))
        )
    ["test", "unit"] -> Just (withCoverage TestUnit)
    ["test", "integration", "all"] -> Just (withCoverage (TestIntegration IntegrationAll))
    ["test", "integration", "cli"] -> Just (withCoverage (TestIntegration IntegrationCli))
    ["test", "integration", "aws-iam"] -> Just (withCoverage (TestIntegration IntegrationAwsIam))
    ["test", "integration", "dns-aws"] -> Just (withCoverage (TestIntegration IntegrationDnsAws))
    ["test", "integration", "aws-eks"] -> Just (withCoverage (TestIntegration IntegrationAwsEks))
    ["test", "integration", "env"] -> Just (withCoverage (TestIntegration IntegrationEnv))
    ["test", "integration", "gateway-daemon"] -> Just (withCoverage (TestIntegration IntegrationGatewayDaemon))
    ["test", "integration", "gateway-pods"] -> Just (withCoverage (TestIntegration IntegrationGatewayPods))
    ["test", "integration", "gateway-partition"] -> Just (withCoverage (TestIntegration IntegrationGatewayPartition))
    ["test", "integration", "ha-rke2-aws"] -> Just (withCoverage (TestIntegration IntegrationHaRke2Aws))
    ["test", "integration", "lifecycle"] -> Just (withCoverage (TestIntegration IntegrationLifecycle))
    ["test", "integration", "pulumi"] -> Just (withCoverage (TestIntegration IntegrationPulumi))
    ["test", "integration", "eks-volume-rebind"] -> Just (withCoverage (TestIntegration IntegrationEksVolumeRebind))
    ["test", "integration", "charts-storage"] -> Just (withCoverage (TestIntegration IntegrationChartsStorage))
    ["test", "integration", "charts-platform"] -> Just (withCoverage (TestIntegration IntegrationChartsPlatform))
    ["test", "integration", "pulsar-broker"] -> Just (withCoverage (TestIntegration IntegrationPulsarBroker))
    ["test", "integration", "charts-vscode"] -> Just (withCoverage (TestIntegration IntegrationChartsVscode))
    ["test", "integration", "charts-api"] -> Just (withCoverage (TestIntegration IntegrationChartsApi))
    ["test", "integration", "charts-websocket"] -> Just (withCoverage (TestIntegration IntegrationChartsWebsocket))
    ["test", "integration", "admin-routes"] -> Just (withCoverage (TestIntegration IntegrationAdminRoutes))
    ["test", "integration", "public-dns"] -> Just (withCoverage (TestIntegration IntegrationPublicDns))
    ["test", "integration", "keycloak-invite"] -> Just (withCoverage (TestIntegration IntegrationKeycloakInvite))
    ["test", "integration", "sealed-vault"] -> Just (withCoverage (TestIntegration IntegrationSealedVault))
    ["nuke"] ->
      Just
        ( fmap
            (RunNative . NativeNuke)
            ( NukeOptions
                <$> switch (long "dry-run" <> help "Render the teardown plan without mutating state")
                <*> optional
                  ( strOption
                      ( long "plan-file"
                          <> metavar "PATH"
                          <> help "Write the rendered plan to a file"
                      )
                  )
            )
        )
    ["dev", "tla-check"] -> Just (pure (RunNative NativeTlaCheck))
    ["workload", "start"] ->
      Just (fmap (RunNative . NativeWorkload . WorkloadStart) workloadOptionsParser)
    _ -> Nothing

commandsTreeParser :: Parser CommandRequest
commandsTreeParser =
  flag'
    (ShowCommands CommandsTree)
    ( long "tree"
        <> help "Render the command registry as a tree"
    )

commandsJsonParser :: Parser CommandRequest
commandsJsonParser =
  flag'
    (ShowCommands CommandsJson)
    ( long "json"
        <> help "Render the command registry as JSON"
    )

coverageFlagsParser :: Parser CoverageFlags
coverageFlagsParser =
  CoverageFlags
    <$> switch
      ( long "coverage"
          <> help "Enable coverage reporting for the selected test scope"
      )
    <*> optional
      ( option
          auto
          ( long "cov-fail-under"
              <> metavar "INTEGER"
              <> help "Require a minimum coverage percentage"
          )
      )

planOptionsParser :: Parser PlanOptions
planOptionsParser =
  PlanOptions
    <$> switch
      ( long "dry-run"
          <> help "Render the plan without mutating state"
      )
    <*> optional
      ( strOption
          ( long "plan-file"
              <> metavar "PATH"
              <> help "Write the rendered plan to a file"
          )
      )

federationRegisterOptionsParser :: Parser FederationRegisterOptions
federationRegisterOptionsParser =
  FederationRegisterOptions
    <$> planOptionsParser
    <*> optional
      ( strOption
          ( long "child-vault-address"
              <> metavar "URL"
              <> help "Host-reachable Vault API address for the child cluster"
          )
      )
    <*> optional
      ( strOption
          ( long "child-kubeconfig"
              <> metavar "PATH"
              <> help "Kubeconfig for applying the child transit-seal token Secret"
          )
      )
    <*> many
      ( option
          keyValueReader
          ( long "child-endpoint"
              <> metavar "NAME=URL"
              <> help "Child endpoint inventory entry to custody in the parent Vault; repeatable"
          )
      )
    <*> optional
      ( strOption
          ( long "child-kubeconfig-reference"
              <> metavar "REF"
              <> help "Parent-custodied kubeconfig reference for the child cluster"
          )
      )
    <*> optional
      ( strOption
          ( long "child-account-id"
              <> metavar "ACCOUNT_ID"
              <> help "Parent-custodied cloud/account identifier for the child cluster"
          )
      )
    <*> many
      ( option
          keyValueReader
          ( long "child-pulumi-stack"
              <> metavar "NAME=REF"
              <> help "Child Pulumi stack reference to custody in the parent Vault; repeatable"
          )
      )

keyValueReader :: ReadM (String, String)
keyValueReader = eitherReader parseKeyValue

parseKeyValue :: String -> Either String (String, String)
parseKeyValue raw =
  case break (== '=') raw of
    ("", _) -> Left "expected NAME=VALUE with a non-empty NAME"
    (_, "") -> Left "expected NAME=VALUE"
    (name, _ : rawValue)
      | null rawValue -> Left "expected NAME=VALUE with a non-empty VALUE"
      | otherwise -> Right (name, rawValue)

-- | @--with-edge@ for @rke2 reconcile@: also reconcile the AWS-gated public
-- edge (Route 53 DNS + ZeroSSL TLS). Bare reconcile is local-only and needs
-- no operational @aws.*@.
withPublicEdgeSwitch :: Parser Bool
withPublicEdgeSwitch =
  switch
    ( long "with-edge"
        <> help
          "Also reconcile the AWS-gated public edge (Route 53 DNS + ZeroSSL TLS); requires operational aws.*"
    )

outputOptionsParser :: Parser OutputOptions
outputOptionsParser =
  OutputOptions
    <$> option
      outputFormatReader
      ( long "format"
          <> metavar "plain|table|json"
          <> value OutputPlain
          <> help "Output format"
      )
    <*> ( noColorParser
            <|> option
              colorModeReader
              ( long "color"
                  <> metavar "auto|always|never"
                  <> value ColorAuto
                  <> help "Color mode"
              )
        )
 where
  noColorParser = flag' ColorNever (long "no-color" <> help "Disable color output")

outputFormatReader :: ReadM OutputFormat
outputFormatReader = eitherReader parseOutputFormat

colorModeReader :: ReadM ColorMode
colorModeReader = eitherReader parseColorMode

parseOutputFormat :: String -> Either String OutputFormat
parseOutputFormat valueText =
  case valueText of
    "plain" -> Right OutputPlain
    "table" -> Right OutputTable
    "json" -> Right OutputJson
    _ -> Left "--format must be one of: plain, table, json"

parseColorMode :: String -> Either String ColorMode
parseColorMode valueText =
  case valueText of
    "auto" -> Right ColorAuto
    "always" -> Right ColorAlways
    "never" -> Right ColorNever
    _ -> Left "--color must be one of: auto, always, never"

withCoverage :: TestScope -> Parser CommandRequest
withCoverage scope =
  (\coverage substrate -> RunNative (NativeTest (TestCommand scope coverage substrate)))
    <$> coverageFlagsParser
    <*> substrateOptionParser

testInitParser :: Parser CommandRequest
testInitParser =
  RunNative
    . NativeTest
    . (\force -> TestCommand (TestInit force) (CoverageFlags False Nothing) defaultSubstrate)
    <$> switch
      ( long "force"
          <> help "Overwrite an existing executable-sibling prodbox.test.dhall"
      )

testRunParser :: Parser CommandRequest
testRunParser =
  ( \suiteName coverage substrate -> RunNative (NativeTest (TestCommand (TestRun suiteName) coverage substrate))
  )
    <$> strArgument (metavar "SUITE")
    <*> coverageFlagsParser
    <*> substrateOptionParser

substrateOptionParser :: Parser Substrate
substrateOptionParser =
  option
    (eitherReader parseSubstrate)
    ( long "substrate"
        <> metavar "SUBSTRATE"
        <> value defaultSubstrate
        <> help "Target substrate (home-local, aws); default home-local"
    )

-- | --port for the @host firewall gateway-restrict@ subcommand. Defaults
-- to the gateway chart's NodePort. The default value is intentionally
-- pinned here rather than read from chart values so the host-side firewall
-- installer remains a pure CLI surface.
gatewayNodePortParser :: Parser Int
gatewayNodePortParser =
  option
    auto
    ( long "port"
        <> metavar "PORT"
        <> value 30443
        <> help "Gateway-service NodePort to restrict to 127.0.0.1 (default: 30443)"
    )

daemonLaunchOptionsParser :: Parser DaemonLaunchOptions
daemonLaunchOptionsParser =
  DaemonLaunchOptions
    <$> optional
      ( strOption
          ( long "config"
              <> metavar "PATH"
              <> help "Gateway config path"
          )
      )
    <*> planOptionsParser

daemonStatusOptionsParser :: Parser DaemonStatusOptions
daemonStatusOptionsParser =
  fmap
    DaemonStatusOptions
    ( optional
        ( strOption
            ( long "config"
                <> metavar "PATH"
                <> help "Gateway config path"
            )
        )
    )

workloadOptionsParser :: Parser WorkloadOptions
workloadOptionsParser =
  WorkloadOptions
    <$> optional
      ( strOption
          ( long "config"
              <> metavar "PATH"
              <> help "Workload Dhall config path (e.g. /etc/workload/config.dhall)"
          )
      )

writeSwitchParser :: Parser Bool
writeSwitchParser =
  switch
    ( long "write"
        <> help "Rewrite the target surface instead of only checking for drift"
    )

-- | Sprint 7.22: build the @aws stack \<stack> prune-corrupt-checkpoint@
-- request for a per-run stack. The 'Bool' is the @--yes@ confirmation.
prunePerRunCheckpointCommand :: PerRunPruneTarget -> Bool -> CommandRequest
prunePerRunCheckpointCommand target confirmed =
  RunNative (NativePulumi (PulumiPruneCorruptCheckpoint target confirmed))

yesSwitchParser :: String -> Parser Bool
yesSwitchParser helpText =
  switch
    ( long "yes"
        <> short 'y'
        <> help helpText
    )

-- | Sprint 4.11: parser for the @prodbox rke2 delete@ flag matrix.
-- @--yes@ is independent; @--cascade@ opts into the full teardown (K8s
-- drain + per-run Pulumi destroys + uninstall + postflight tag sweep).
-- The default (no @--cascade@) is a pure local cluster uninstall that
-- never touches the per-run AWS Pulumi backend.
rke2DeleteFlagsParser :: Parser Rke2DeleteFlags
rke2DeleteFlagsParser =
  Rke2DeleteFlags
    <$> yesSwitchParser "Confirm full local cluster deletion"
    <*> switch
      ( long "cascade"
          <> help
            ( "Orchestrate the full teardown — K8s drain, per-run "
                ++ "Pulumi destroys, cluster uninstall, postflight tag "
                ++ "sweep — as one atomic operator action. The K8s drain "
                ++ "phase skips gracefully when no cluster is reachable. "
                ++ "Without --cascade, `cluster delete` is a pure local "
                ++ "uninstall and leaves per-run AWS stacks untouched."
            )
      )

-- | Sprint 4.11: build an 'Rke2Delete' request from parsed flags.
rke2DeleteParser :: Rke2DeleteFlags -> PlanOptions -> CommandRequest
rke2DeleteParser flags planOptions =
  RunNative (NativeRke2 (Rke2Delete flags planOptions))

-- | Sprint 7.7 — parser for the two mutually-exclusive Pulumi-residue
-- flags on @prodbox aws teardown@.
--
-- * @--destroy-pulumi-residue@ → 'DestroyPulumiResidueFirst': run each
--   live stack's canonical destroy command before the IAM teardown.
-- * @--allow-pulumi-residue@ → 'AcceptOrphanResidue' (Sprint 7.6 escape
--   hatch): bypass the residue refuse-path entirely.
-- * neither → 'RefuseOnAnyResidue' (default): refuse if any stack is live.
--
-- Mutual exclusion is enforced by the @flag' \<|> flag' \<|> pure@
-- idiom: each @flag'@ requires its flag's presence to match. When both
-- flags appear, the first @flag'@ matches and consumes its flag, but
-- the second flag is unconsumed by any matching parser and
-- optparse-applicative reports it as an unknown option, exiting
-- non-zero at parse time with an actionable message. The pure helper
-- 'awsTeardownPolicyFromFlags' covers the same matrix for unit tests.
awsTeardownFlagsParser :: Parser AwsTeardownFlags
awsTeardownFlagsParser =
  AwsTeardownFlags
    <$> ( flag'
            DestroyPulumiResidueFirst
            ( long "destroy-pulumi-residue"
                <> help
                  ( "Run `prodbox aws stack <stack> destroy --yes` for each "
                      ++ "live Pulumi-managed AWS stack (in canonical "
                      ++ "order: aws-eks-subzone, aws-eks, aws-test, "
                      ++ "aws-ses) before deleting the operational IAM "
                      ++ "user. Mutually exclusive with "
                      ++ "--allow-pulumi-residue. Destroying the "
                      ++ "long-lived aws-ses stack triggers a 5-30 min "
                      ++ "SES re-verification + ~24h S3 bucket name "
                      ++ "cooldown."
                  )
            )
            <|> flag'
              AcceptOrphanResidue
              ( long "allow-pulumi-residue"
                  <> help
                    ( "Bypass the refuse-path check that prevents "
                        ++ "deleting the operational IAM user while "
                        ++ "Pulumi-managed AWS stacks still have live "
                        ++ "resources. Operator-acknowledged recovery "
                        ++ "only; stacks become orphaned. Mutually "
                        ++ "exclusive with --destroy-pulumi-residue."
                    )
              )
            <|> pure RefuseOnAnyResidue
        )

-- | Sprint 7.7 — pure smart constructor exposed for unit tests. The
-- parser itself cannot easily call this because optparse-applicative
-- 'switch' loses the "exactly one flag" signal once both Bools become
-- True; the 'flag' + \<|>' idiom in 'awsTeardownFlagsParser' enforces
-- mutual exclusion at parse time. This helper covers the same matrix
-- so the unit tests can assert on the four legal combinations without
-- exercising the full optparse-applicative dispatch.
awsTeardownPolicyFromFlags :: Bool -> Bool -> Either String PulumiResiduePolicy
awsTeardownPolicyFromFlags True True =
  Left
    ( "Flags --allow-pulumi-residue and --destroy-pulumi-residue are "
        ++ "mutually exclusive; pass at most one."
    )
awsTeardownPolicyFromFlags True False = Right AcceptOrphanResidue
awsTeardownPolicyFromFlags False True = Right DestroyPulumiResidueFirst
awsTeardownPolicyFromFlags False False = Right RefuseOnAnyResidue

defaultNamespaces :: [String] -> [String]
defaultNamespaces namespaces =
  case namespaces of
    [] -> defaultInfrastructureNamespaces
    _ -> namespaces

tierOptionParser :: PolicyTier -> String -> Parser PolicyTier
tierOptionParser defaultTier helpText =
  option
    (eitherReader parseTier)
    ( long "tier"
        <> value defaultTier
        <> metavar "TIER"
        <> help helpText
    )

parseTier :: String -> Either String PolicyTier
parseTier rawTier =
  case rawTier of
    "core" -> Right PolicyCore
    "full" -> Right PolicyFull
    _ -> Left "--tier must be one of: core, full"

manyStringsOption :: String -> Char -> String -> Parser [String]
manyStringsOption longName shortName helpText =
  many
    ( strOption
        ( long longName
            <> short shortName
            <> metavar "VALUE"
            <> help helpText
        )
    )

flagOption :: String -> Maybe Char -> Maybe String -> String -> OptionSpec
flagOption longName' shortName' metavar' helpText =
  OptionSpec
    { longName = longName'
    , shortName = shortName'
    , optionMetavar = metavar'
    , description = helpText
    , required = False
    }

requiredOption :: String -> Maybe Char -> String -> String -> OptionSpec
requiredOption longName' shortName' metavar' helpText =
  OptionSpec
    { longName = longName'
    , shortName = shortName'
    , optionMetavar = Just metavar'
    , description = helpText
    , required = True
    }

optionalOption :: String -> Maybe Char -> String -> String -> OptionSpec
optionalOption longName' shortName' metavar' helpText =
  OptionSpec
    { longName = longName'
    , shortName = shortName'
    , optionMetavar = Just metavar'
    , description = helpText
    , required = False
    }

-- | A required, single-valued positional argument.
argument :: String -> String -> String -> ArgumentSpec
argument argName metavarText helpText =
  ArgumentSpec
    { argumentName = argName
    , argumentMetavar = metavarText
    , argumentDescription = helpText
    , argumentOptional = False
    , argumentRepeatable = False
    }

-- | A required, repeatable positional argument (e.g. @help
-- \<COMMAND_PATH...\>@).
repeatableArgument :: String -> String -> String -> ArgumentSpec
repeatableArgument argName metavarText helpText =
  (argument argName metavarText helpText) {argumentRepeatable = True}

example :: [String] -> String -> Example
example = Example

leaf :: String -> String -> String -> [OptionSpec] -> [Example] -> CommandSpec
leaf nodeName nodeSummary nodeDescription = leafWithArgs nodeName nodeSummary nodeDescription []

-- | Like 'leaf' but with a typed positional-argument list. The
-- positionals are documentation source only (the parser keeps its own
-- 'optparse-applicative' bindings); the generated command-surface matrix
-- renders them in its "Arguments" column.
leafWithArgs
  :: String -> String -> String -> [ArgumentSpec] -> [OptionSpec] -> [Example] -> CommandSpec
leafWithArgs nodeName nodeSummary nodeDescription nodeArguments nodeOptions nodeExamples =
  CommandSpec
    { name = nodeName
    , summary = nodeSummary
    , description = nodeDescription
    , children = []
    , arguments = nodeArguments
    , options = nodeOptions
    , examples = nodeExamples
    }

group :: String -> String -> String -> [CommandSpec] -> [OptionSpec] -> [Example] -> CommandSpec
group nodeName nodeSummary nodeDescription nodeChildren nodeOptions nodeExamples =
  CommandSpec
    { name = nodeName
    , summary = nodeSummary
    , description = nodeDescription
    , children = nodeChildren
    , arguments = []
    , options = nodeOptions
    , examples = nodeExamples
    }

configGroup :: CommandSpec
configGroup =
  group
    "config"
    "Configuration management"
    "Repository-root Dhall configuration commands."
    [ leaf
        "setup"
        "Interactively author config"
        "Write the supported prodbox Dhall config."
        [ flagOption "dry-run" Nothing Nothing "Render the config-setup plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [example ["config", "setup"] "Create or refresh the config interactively."]
    , leaf
        "show"
        "Display current config"
        "Render the decoded config with secrets masked by default."
        [flagOption "show-secrets" Nothing Nothing "Show full secret values"]
        [example ["config", "show"] "Render the current config with secrets masked."]
    , leaf
        "validate"
        "Validate current config"
        "Validate the repository-root config file."
        []
        [example ["config", "validate"] "Validate the current config."]
    , leaf
        "schema"
        "Regenerate Dhall schema files"
        "Regenerate prodbox-config-types.dhall + test-secrets-types.dhall from the Haskell source of truth."
        []
        [example ["config", "schema"] "Regenerate the committed Dhall schema files."]
    , leaf
        "generate"
        "Generate the default non-secret config"
        "Non-interactively write a default, non-secret prodbox.dhall from the Haskell source of truth when it is absent; leaves an existing file unchanged (idempotent)."
        []
        [example ["config", "generate"] "Generate prodbox.dhall from defaults for a headless bring-up."]
    ]
    []
    [example ["config", "validate"] "Validate the config before running lifecycle commands."]

awsGroup :: CommandSpec
awsGroup =
  group
    "aws"
    "AWS IAM and quota management"
    "Operational AWS administration commands."
    [ leaf
        "policy"
        "Render IAM policy JSON"
        "Render the doctrine-owned IAM policy document."
        [optionalOption "tier" Nothing "TIER" "Operational IAM policy tier to render"]
        [example ["aws", "policy", "--tier", "full"] "Render the full IAM policy document."]
    , leaf
        "setup"
        "Create or refresh operational IAM user"
        "Provision or refresh the operational IAM user."
        [ optionalOption "tier" Nothing "TIER" "Operational IAM policy tier to provision"
        , flagOption "dry-run" Nothing Nothing "Render the IAM setup plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [example ["aws", "setup", "--tier", "full"] "Create or refresh the operational IAM user."]
    , leaf
        "teardown"
        "Delete operational IAM user"
        "Delete the operational IAM user. Default mode opens with a Pulumi-residue check and refuses if any AWS substrate stack (`aws-eks`, `aws-eks-subzone`, `aws-test`, `aws-ses`) still owns live resources. `--destroy-pulumi-residue` orchestrates `prodbox aws stack <stack> destroy --yes` (the `<stack>` CLI verb is `eks`/`aws-subzone`/`test`/`aws-ses`, not the registry name) in canonical order before deleting the operational IAM user; destroying the long-lived `aws-ses` stack triggers a 5-30 min SES re-verification and ~24h S3 bucket-name cooldown. `--allow-pulumi-residue` is the operator-acknowledged recovery escape hatch that bypasses the residue check entirely (stacks become orphaned). `--destroy-pulumi-residue` and `--allow-pulumi-residue` are mutually exclusive at parse time."
        [ flagOption "dry-run" Nothing Nothing "Render the IAM teardown plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        , flagOption
            "destroy-pulumi-residue"
            Nothing
            Nothing
            "Run `prodbox aws stack <stack> destroy --yes` for each live Pulumi-managed AWS stack in canonical order before deleting the operational IAM user (mutually exclusive with --allow-pulumi-residue)"
        , flagOption
            "allow-pulumi-residue"
            Nothing
            Nothing
            "Bypass the Pulumi-residue refuse-path that prevents deleting the operational IAM user while AWS substrate stacks still have live resources (operator-acknowledged recovery only; mutually exclusive with --destroy-pulumi-residue)"
        ]
        [ example
            ["aws", "teardown"]
            "Delete the operational IAM user (refuses if any AWS substrate stack is live)."
        , example
            ["aws", "teardown", "--destroy-pulumi-residue"]
            "Destroy live AWS substrate stacks in canonical order, then delete the operational IAM user."
        ]
    , group
        "quotas"
        "Inspect or request AWS quotas"
        "Inspect supported AWS quotas and request quota increases."
        [ leaf
            "check"
            "Inspect supported AWS quotas"
            "Inspect supported AWS quotas."
            []
            [example ["aws", "quotas", "check"] "Inspect AWS quotas."]
        , leaf
            "request"
            "Request supported AWS quotas"
            "Request supported AWS quota increases."
            [optionalOption "tier" Nothing "TIER" "Quota target tier to request"]
            [example ["aws", "quotas", "request", "--tier", "core"] "Request core-tier quota increases."]
        ]
        []
        [example ["aws", "quotas", "check"] "Inspect AWS quotas."]
    , group
        "ebs"
        "AWS EBS maintenance"
        "Recover test-scoped EBS volumes left behind after AWS-substrate test runs."
        [ leaf
            "reap-test"
            "Delete test-scoped EBS volumes"
            "Delete only EBS volumes tagged as per-run test volumes for the canonical AWS EKS test cluster. Retained-production EBS volumes are never selected."
            [flagOption "yes" Nothing Nothing "Confirm deletion of test-scoped EBS volumes"]
            [example ["aws", "ebs", "reap-test", "--yes"] "Delete leaked test-scoped EBS volumes."]
        ]
        []
        [example ["aws", "ebs", "reap-test", "--yes"] "Delete leaked test-scoped EBS volumes."]
    , awsStackGroup
    ]
    []
    [example ["aws", "policy"] "Inspect the IAM policy without mutating AWS."]

hostGroup :: CommandSpec
hostGroup =
  group
    "host"
    "Host prerequisite checks"
    "Host diagnostics and public-edge validation."
    [ leaf
        "ensure-tools"
        "Verify required host tools"
        "Check the supported host toolchain."
        []
        [example ["host", "ensure-tools"] "Verify required host tools are installed."]
    , leaf
        "check-ports"
        "Check required ports"
        "Check required host ports."
        []
        [example ["host", "check-ports"] "Inspect required host ports."]
    , leaf
        "info"
        "Display host diagnostics"
        "Show host diagnostics."
        []
        [example ["host", "info"] "Render host diagnostics."]
    , group
        "firewall"
        "Manage host firewall rules"
        "Subcommands install or remove gateway-NodePort restrictions."
        [ leaf
            "gateway-restrict"
            "Restrict the gateway NodePort to 127.0.0.1"
            "Install an idempotent iptables INPUT-DROP rule restricting the gateway NodePort to loopback ingress."
            [ optionalOption "port" Nothing "PORT" "Gateway-service NodePort to restrict (default: 30443)"
            ]
            [ example
                ["host", "firewall", "gateway-restrict"]
                "Install the loopback-only restriction on the default NodePort."
            , example
                ["host", "firewall", "gateway-restrict", "--port", "30443"]
                "Install the restriction on an explicit NodePort."
            ]
        , leaf
            "gateway-unrestrict"
            "Remove the gateway NodePort loopback restriction"
            "Remove the idempotent iptables INPUT-DROP rule that restricts the gateway NodePort to loopback ingress. Safe to call when the rule is absent (reports `not-present` and exits 0)."
            [ optionalOption "port" Nothing "PORT" "Gateway-service NodePort to unrestrict (default: 30443)"
            ]
            [ example
                ["host", "firewall", "gateway-unrestrict"]
                "Remove the loopback-only restriction on the default NodePort."
            , example
                ["host", "firewall", "gateway-unrestrict", "--port", "30443"]
                "Remove the restriction on an explicit NodePort."
            ]
        ]
        []
        []
    ]
    []
    [example ["host", "info"] "Render host information."]

dnsGroup :: CommandSpec
dnsGroup =
  group
    "dns"
    "Route 53 inspection"
    "DNS inspection commands."
    [ leaf
        "check"
        "Inspect Route 53 state"
        "Inspect Route 53 ownership state."
        []
        [example ["dns", "check"] "Inspect Route 53 state."]
    ]
    []
    [example ["dns", "check"] "Inspect Route 53 ownership."]

gatewayGroup :: CommandSpec
gatewayGroup =
  group
    "gateway"
    "Gateway daemon operations"
    "Distributed gateway daemon commands."
    [ leaf
        "start"
        "Start gateway daemon"
        "Start the distributed gateway daemon."
        [ optionalOption "config" Nothing "PATH" "Gateway config path"
        , flagOption "dry-run" Nothing Nothing "Render the daemon-start plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [example ["gateway", "start", "--config", "gateway.dhall"] "Start the gateway daemon."]
    , leaf
        "status"
        "Query gateway daemon status"
        "Query the gateway daemon status surface."
        [optionalOption "config" Nothing "PATH" "Gateway config path"]
        [example ["gateway", "status", "--config", "gateway.dhall"] "Inspect the gateway daemon state."]
    , leafWithArgs
        "config-gen"
        "Generate gateway config"
        "Generate a gateway config template."
        [argument "output-path" "OUTPUT_PATH" "Path to write the generated gateway config to"]
        [requiredOption "node-id" Nothing "NODE_ID" "Node ID for the generated config"]
        [ example
            ["gateway", "config-gen", "gateway.json", "--node-id", "node-a"]
            "Generate a gateway config template."
        ]
    ]
    []
    [example ["gateway", "status", "--config", "gateway.dhall"] "Inspect gateway daemon state."]

usersGroup :: CommandSpec
usersGroup =
  group
    "users"
    "Operator-invited user management"
    "Operator-facing Keycloak user management surface for the Phase 8 invite flow."
    [ leafWithArgs
        "invite"
        "Invite an operator-owned user by email"
        "Create a Keycloak user with emailVerified=false and trigger the SES-backed invite email."
        [argument "email" "EMAIL" "Email address of the user to invite"]
        [ optionalOption "role" Nothing "ROLE" "Operator-defined role to assign on invite"
        , flagOption "dry-run" Nothing Nothing "Render the invite plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [ example
            ["users", "invite", "operator@example.invalid"]
            "Invite operator@example.invalid to set up an account."
        , example
            ["users", "invite", "operator@example.invalid", "--role", "admin"]
            "Invite an operator with the admin role assignment."
        ]
    , leaf
        "list"
        "List operator-managed users"
        "List Keycloak users with their email-verification status and last-login time."
        [ flagOption
            "status"
            (Just 's')
            Nothing
            "Filter the listing by status (default all; --status alone selects verified)"
        , flagOption
            "status-unverified"
            Nothing
            Nothing
            "Restrict the listing to users whose email is not yet verified"
        ]
        [ example ["users", "list"] "List all operator-managed users."
        , example ["users", "list", "--status"] "List only email-verified users."
        , example
            ["users", "list", "--status-unverified"]
            "List users awaiting invite activation."
        ]
    , leafWithArgs
        "revoke"
        "Disable or delete an operator-managed user"
        "Revoke an operator-managed user. Disables the user by default; pass --delete to fully remove the user."
        [argument "email-or-user-id" "EMAIL_OR_USER_ID" "Email address or Keycloak user ID to revoke"]
        [ flagOption "delete" Nothing Nothing "Fully delete the user instead of disabling"
        , flagOption "dry-run" Nothing Nothing "Render the revoke plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [ example
            ["users", "revoke", "operator@example.invalid"]
            "Disable the operator account."
        , example
            ["users", "revoke", "operator@example.invalid", "--delete"]
            "Fully delete the operator account."
        ]
    ]
    []
    [example ["users", "invite", "operator@example.invalid"] "Invite a new operator-owned user."]

workloadGroup :: CommandSpec
workloadGroup =
  group
    "workload"
    "Internal public workload runtime"
    "Internal workload daemon commands."
    [ leaf
        "start"
        "Start internal workload runtime"
        "Start the internal workload daemon."
        [ optionalOption
            "config"
            Nothing
            "PATH"
            "Workload Dhall config path (e.g. /etc/workload/config.dhall)"
        ]
        [example ["workload", "start"] "Start the internal workload runtime."]
    ]
    []
    [example ["workload", "start"] "Start the internal workload runtime."]

chartsGroup :: CommandSpec
chartsGroup =
  group
    "charts"
    "Bespoke Helm chart lifecycle"
    "Supported chart lifecycle commands."
    [ leaf
        "list"
        "List supported charts"
        "List supported root charts."
        []
        [example ["charts", "list"] "List supported root charts."]
    , leafWithArgs
        "status"
        "Show detailed chart status"
        "Inspect the current state of a root chart."
        [chartArgument]
        []
        [example ["charts", "status", "vscode"] "Inspect the vscode chart status."]
    , leafWithArgs
        "reconcile"
        "Reconcile a root chart stack"
        "Reconcile a root chart to the supported state."
        [chartArgument]
        [ flagOption "dry-run" Nothing Nothing "Render the deployment plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        , optionalOption
            "substrate"
            Nothing
            "SUBSTRATE"
            "Target substrate (home-local, aws); default home-local"
        ]
        [ example ["charts", "reconcile", "vscode"] "Reconcile the vscode stack."
        , example ["charts", "reconcile", "--dry-run", "vscode"] "Render the chart deployment plan."
        ]
    , leafWithArgs
        "delete"
        "Delete a root chart stack"
        "Delete a root chart stack."
        [chartArgument]
        [ flagOption "yes" (Just 'y') Nothing "Skip confirmation prompt"
        , flagOption "dry-run" Nothing Nothing "Render the deletion plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        , optionalOption
            "substrate"
            Nothing
            "SUBSTRATE"
            "Target substrate (home-local, aws); default home-local"
        ]
        [ example ["charts", "delete", "vscode", "--yes"] "Delete the vscode stack."
        , example ["charts", "delete", "--dry-run", "vscode"] "Render the chart deletion plan."
        ]
    ]
    []
    [example ["charts", "list"] "List supported root charts."]
 where
  chartArgument =
    argument "chart" "CHART" "Root chart name (gateway, keycloak, vscode, api, websocket)"

-- | @prodbox aws stack ...@ — the Pulumi-backed AWS substrate stacks,
-- regrouped under `aws` (Phase 5; the tool name `pulumi` no longer leaks
-- into the surface). Each stack exposes the canonical `reconcile` /
-- `destroy` verbs; `aws-ses` adds the one-time `migrate-backend`.
awsStackGroup :: CommandSpec
awsStackGroup =
  group
    "stack"
    "AWS substrate stack lifecycle"
    "Reconcile and destroy the Pulumi-backed AWS substrate validation stacks."
    [ stackVerbGroup
        "eks"
        "EKS validation stack"
        "Reconcile the EKS validation stack."
        "Destroy the EKS validation stack."
        [pruneCorruptCheckpointLeaf "eks"]
    , stackVerbGroup
        "test"
        "HA RKE2 validation stack"
        "Reconcile the HA RKE2 validation stack."
        "Destroy the HA RKE2 validation stack."
        [pruneCorruptCheckpointLeaf "test"]
    , stackVerbGroup
        "aws-subzone"
        "Per-substrate Route 53 subzone"
        "Reconcile the AWS-substrate Route 53 hosted subzone and NS delegation."
        "Destroy the AWS-substrate Route 53 hosted subzone and remove the parent NS delegation."
        [pruneCorruptCheckpointLeaf "aws-subzone"]
    , stackVerbGroup
        "aws-ses"
        "Cross-substrate AWS SES infrastructure"
        "Reconcile the shared AWS SES sending identity, receive subdomain, receive rule set, S3 capture bucket, and SMTP IAM user used by Phase 8 operator-invited email auth."
        "Destroy the shared AWS SES stack (sending identity, receive subdomain, receive rule set, S3 capture bucket, and SMTP IAM user)."
        [ leaf
            "migrate-backend"
            "Migrate aws-ses Pulumi state onto the long-lived S3 backend"
            "Operator-interactive command: migrate the `aws-ses` stack's Pulumi state from the in-cluster MinIO backend onto the dedicated long-lived S3 bucket named by `pulumi_state_backend` in `prodbox.dhall`. Idempotent; no-op when the stack already lives in the long-lived backend. TTY-only; refuses non-interactive contexts."
            [ flagOption "dry-run" Nothing Nothing "Render the migration plan without mutating state"
            , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
            ]
            [ example
                ["aws", "stack", "aws-ses", "migrate-backend"]
                "Migrate aws-ses state onto the long-lived S3 backend."
            ]
        ]
    ]
    []
    [example ["aws", "stack", "eks", "reconcile"] "Reconcile the EKS validation stack."]

-- | Sprint 7.22: the @prune-corrupt-checkpoint@ recovery leaf for a per-run
-- stack group. Per-run stacks only — a corrupt long-lived @aws-ses@
-- checkpoint always refuses.
pruneCorruptCheckpointLeaf :: String -> CommandSpec
pruneCorruptCheckpointLeaf stackName =
  leaf
    "prune-corrupt-checkpoint"
    ("Clear a corrupt " ++ stackName ++ " per-run Pulumi checkpoint")
    ( "Recovery: clear a genuinely-corrupt (or empty) per-run encrypted Pulumi checkpoint for the "
        ++ stackName
        ++ " stack from the Model-B object store, so a cluster carrying stale corrupt checkpoints (truncated leftovers from an interrupted run) can converge. Observes the checkpoint first and refuses to prune a valid (present) checkpoint — use `destroy` for that. Fail-closed on an unobservable backend."
    )
    [flagOption "yes" (Just 'y') Nothing "Skip confirmation prompts"]
    [ example
        ["aws", "stack", stackName, "prune-corrupt-checkpoint", "--yes"]
        ("Clear a corrupt " ++ stackName ++ " per-run checkpoint.")
    ]

-- | One @aws stack <name>@ subgroup with the canonical @reconcile@ /
-- @destroy@ verbs plus any extra leaves (e.g. @aws-ses migrate-backend@).
stackVerbGroup :: String -> String -> String -> String -> [CommandSpec] -> CommandSpec
stackVerbGroup stackName summaryText reconcileDescription destroyDescription extraLeaves =
  group
    stackName
    summaryText
    ("Lifecycle for the " ++ stackName ++ " AWS substrate stack.")
    ( [ leaf
          "reconcile"
          ("Provision or inspect the " ++ stackName ++ " stack")
          reconcileDescription
          [ flagOption "dry-run" Nothing Nothing "Render the Pulumi plan without mutating state"
          , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
          ]
          [example ["aws", "stack", stackName, "reconcile"] reconcileDescription]
      , leaf
          "destroy"
          ("Destroy the " ++ stackName ++ " stack")
          destroyDescription
          [ flagOption "yes" (Just 'y') Nothing "Skip confirmation prompts"
          , flagOption "dry-run" Nothing Nothing "Render the destroy plan without mutating state"
          , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
          ]
          [example ["aws", "stack", stackName, "destroy", "--yes"] destroyDescription]
      ]
        ++ extraLeaves
    )
    []
    [example ["aws", "stack", stackName, "reconcile"] reconcileDescription]

clusterGroup :: CommandSpec
clusterGroup =
  group
    "cluster"
    "Local cluster lifecycle"
    "Local Kubernetes cluster lifecycle. AWS-free: every command here decodes config and runs with an empty aws.* block. Public DNS + TLS lives under `prodbox edge`."
    [ leaf
        "status"
        "Check cluster and Vault status"
        "Inspect the local cluster service status and the in-cluster Vault seal state."
        []
        [example ["cluster", "status"] "Inspect local cluster and Vault status."]
    , leaf
        "health"
        "Check Kubernetes health"
        "Inspect Kubernetes cluster health."
        []
        [example ["cluster", "health"] "Inspect Kubernetes health."]
    , leaf
        "start"
        "Start the cluster service"
        "Start the local cluster service."
        []
        [example ["cluster", "start"] "Start the local cluster."]
    , leaf
        "stop"
        "Stop the cluster service"
        "Stop the local cluster service."
        []
        [example ["cluster", "stop"] "Stop the local cluster."]
    , leaf
        "restart"
        "Restart the cluster service"
        "Restart the local cluster service."
        []
        [example ["cluster", "restart"] "Restart the local cluster."]
    , leaf
        "reconcile"
        "Reconcile the local cluster"
        "Reconcile the supported local cluster state. Local-only by default (no AWS); pass --with-edge to also reconcile the public edge (or run `prodbox edge reconcile` separately)."
        [ flagOption "dry-run" Nothing Nothing "Render the lifecycle plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        , flagOption
            "with-edge"
            Nothing
            Nothing
            "Also reconcile the AWS-gated public edge (Route 53 DNS + ZeroSSL TLS); requires operational aws.*"
        ]
        [ example ["cluster", "reconcile"] "Reconcile the supported local cluster (no AWS needed)."
        , example ["cluster", "reconcile", "--dry-run"] "Render the lifecycle plan."
        , example ["cluster", "reconcile", "--with-edge"] "Reconcile the cluster and attach the public edge."
        ]
    , leaf
        "delete"
        "Delete the local cluster"
        "Delete the local cluster. Default mode is a PURE LOCAL UNINSTALL: it uninstalls RKE2 and preserves `.data/` (including the MinIO-backed per-run Pulumi state and the durable Vault PV) without querying, gating on, or destroying the per-run AWS Pulumi backend — so per-run AWS stacks (if any) are left untouched and remain destroyable afterward via `prodbox cluster delete --cascade` or `prodbox aws stack <name> destroy --yes`. `--cascade` orchestrates the full teardown (K8s drain + per-run Pulumi destroys + cluster uninstall + postflight tag sweep) as one atomic operator action; the K8s drain phase skips gracefully when no cluster is reachable."
        [ flagOption "yes" (Just 'y') Nothing "Confirm full cluster deletion"
        , flagOption
            "cascade"
            Nothing
            Nothing
            "Orchestrate the full teardown (K8s drain + per-run Pulumi destroys + cluster uninstall + postflight tag sweep) as one atomic operator action"
        , flagOption "dry-run" Nothing Nothing "Render the delete plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [ example
            ["cluster", "delete", "--yes"]
            "Uninstall the local cluster (pure local uninstall; leaves per-run AWS stacks untouched)."
        , example
            ["cluster", "delete", "--yes", "--cascade"]
            "Orchestrate the full teardown including per-run AWS destroys."
        ]
    , leaf
        "logs"
        "Show cluster service logs"
        "Show the local cluster service (RKE2) journal logs."
        [optionalOption "lines" (Just 'n') "INTEGER" "Number of log lines to show"]
        [example ["cluster", "logs", "--lines", "50"] "Show recent cluster service logs."]
    , group
        "federation"
        "Downstream cluster custody"
        "Downstream-cluster federation custody. Registering a child provisions the parent-owned Transit key, metadata, and child bootstrap token; dry-run renders the parent-owned Vault KV and opaque-name plan."
        [ leafWithArgs
            "register"
            "Register a downstream cluster"
            "Register parent-owned custody for a downstream cluster: child metadata, child init-key custody path, opaque Vault namespace, Transit key name, and the child bootstrap token Secret."
            [argument "child" "CHILD" "Downstream cluster id to register"]
            [ flagOption "dry-run" Nothing Nothing "Render the registration plan without mutating state"
            , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
            , optionalOption
                "child-vault-address"
                Nothing
                "URL"
                "Host-reachable Vault API address for the child cluster"
            , optionalOption
                "child-kubeconfig"
                Nothing
                "PATH"
                "Kubeconfig for applying the child transit-seal token Secret"
            , optionalOption
                "child-endpoint"
                Nothing
                "NAME=URL"
                "Child endpoint inventory entry to custody in the parent Vault; repeatable"
            , optionalOption
                "child-kubeconfig-reference"
                Nothing
                "REF"
                "Parent-custodied kubeconfig reference for the child cluster"
            , optionalOption
                "child-account-id"
                Nothing
                "ACCOUNT_ID"
                "Parent-custodied cloud/account identifier for the child cluster"
            , optionalOption
                "child-pulumi-stack"
                Nothing
                "NAME=REF"
                "Child Pulumi stack reference to custody in the parent Vault; repeatable"
            ]
            [ example
                ["cluster", "federation", "register", "child-a", "--dry-run"]
                "Render the downstream custody plan."
            , example
                [ "cluster"
                , "federation"
                , "register"
                , "child-a"
                , "--child-vault-address"
                , "http://child-vault.example:8200"
                , "--child-kubeconfig"
                , "/secure/child-a.kubeconfig"
                , "--child-kubeconfig-reference"
                , "vault:secret/clusters/child-a/kubeconfig"
                , "--child-account-id"
                , "123456789012"
                , "--child-endpoint"
                , "api=https://api.child-a.example"
                , "--child-pulumi-stack"
                , "aws-eks=org/prodbox-child-a/aws-eks"
                ]
                "Register child-a and apply its transit-seal token Secret."
            ]
        ]
        []
        [ example
            ["cluster", "federation", "register", "child-a", "--dry-run"]
            "Render the downstream custody plan."
        ]
    , leaf
        "wait"
        "Wait for deployments to be ready"
        "Wait for named namespaces to become ready."
        [ optionalOption "timeout" (Just 't') "INTEGER" "Timeout in seconds"
        , optionalOption "namespace" (Just 'n') "VALUE" "Namespace to wait for"
        ]
        [example ["cluster", "wait", "--timeout", "300"] "Wait for infrastructure workloads."]
    , leaf
        "workload-logs"
        "Show recent workload logs"
        "Show recent logs from infrastructure/workload namespaces."
        [ optionalOption "namespace" (Just 'n') "VALUE" "Namespace to get logs from"
        , optionalOption "tail" Nothing "INTEGER" "Number of log lines per container"
        ]
        [example ["cluster", "workload-logs", "--tail", "25"] "Show recent workload logs."]
    ]
    []
    [example ["cluster", "reconcile"] "Reconcile the supported local cluster state."]

edgeGroup :: CommandSpec
edgeGroup =
  group
    "edge"
    "Public DNS + TLS edge"
    "The AWS-gated public edge: Route 53 DNS records and ZeroSSL DNS-01 TLS. Requires operational aws.* (run `prodbox aws setup` first)."
    [ leaf
        "reconcile"
        "Reconcile the public edge"
        "Reconcile the public edge: the ZeroSSL DNS-01 ClusterIssuer and the Route 53 bootstrap record. Requires operational aws.*; fails fast naming `prodbox aws setup` when it is empty."
        [ flagOption "dry-run" Nothing Nothing "Render the edge plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [ example ["edge", "reconcile"] "Reconcile Route 53 DNS + ZeroSSL TLS for the public edge."
        , example ["edge", "reconcile", "--dry-run"] "Render the edge plan."
        ]
    , leaf
        "status"
        "Check public DNS/TLS edge state"
        "Inspect Route 53, certificate, shared-host readiness, and the in-cluster Vault seal state."
        [substrateOption]
        [ example ["edge", "status"] "Inspect public-edge readiness (home substrate)."
        , example
            ["edge", "status", "--substrate", "aws"]
            "Inspect public-edge readiness on the AWS substrate."
        ]
    ]
    []
    [example ["edge", "reconcile"] "Reconcile the public edge (DNS + TLS)."]

vaultGroup :: CommandSpec
vaultGroup =
  group
    "vault"
    "Vault secret-management lifecycle"
    "The in-cluster Vault lifecycle: seal-status, init, unseal, reconcile, key rotation, and PKI inspection. The encrypted unlock bundle lives in the durable MinIO bucket (host disk holds no unseal material) and recovers a torn-down cluster's Vault."
    [ leaf
        "status"
        "Report Vault seal state"
        "Probe the in-cluster Vault and report initialized / sealed / unseal-progress, or that it is unreachable."
        []
        [example ["vault", "status"] "Probe the in-cluster Vault seal state."]
    , leaf
        "init"
        "Initialize Vault"
        "Initialize an uninitialized Vault, capturing the unseal/recovery keys and root token into the encrypted unlock bundle exactly once."
        []
        [example ["vault", "init"] "Initialize Vault and write the encrypted unlock bundle."]
    , leaf
        "unseal"
        "Unseal Vault"
        "Decrypt the host-side unlock bundle and submit the unseal keys until Vault is unsealed."
        []
        [example ["vault", "unseal"] "Unseal Vault from the encrypted unlock bundle."]
    , leaf
        "seal"
        "Seal Vault"
        "Seal Vault, returning the cluster to the fail-closed state."
        []
        [example ["vault", "seal"] "Seal Vault."]
    , leaf
        "reconcile"
        "Reconcile Vault policy"
        "Idempotently reconcile Vault auth mounts, policies, roles, KV mounts, Transit keys, PKI issuers, and Kubernetes auth roles."
        []
        [example ["vault", "reconcile"] "Reconcile Vault mounts, policies, and keys."]
    , leaf
        "rotate-unlock-bundle"
        "Re-encrypt the unlock bundle"
        "Re-encrypt the host-side unlock bundle under a new password."
        []
        [example ["vault", "rotate-unlock-bundle"] "Re-encrypt the unlock bundle under a new password."]
    , leafWithArgs
        "rotate-transit-key"
        "Rotate a Transit key"
        "Rotate a named Vault Transit envelope key to a new version."
        [argument "key" "KEY" "The Transit key name to rotate"]
        []
        [example ["vault", "rotate-transit-key", "prodbox-minio-envelope"] "Rotate the named Transit key."]
    , group
        "pki"
        "Vault PKI inspection"
        "Inspect the Vault PKI issuer and issue a throwaway certificate to validate it."
        [ leaf
            "status"
            "Report Vault PKI state"
            "Report the Vault PKI issuer and certificate state."
            []
            [example ["vault", "pki", "status"] "Report Vault PKI issuer state."]
        , leaf
            "issue-test-cert"
            "Issue a throwaway PKI cert"
            "Issue a throwaway certificate from Vault PKI to validate the issuer."
            []
            [example ["vault", "pki", "issue-test-cert"] "Issue a throwaway Vault PKI certificate."]
        ]
        []
        [example ["vault", "pki", "status"] "Report Vault PKI issuer state."]
    ]
    []
    [example ["vault", "status"] "Probe the in-cluster Vault seal state."]

testGroupSpec :: CommandSpec
testGroupSpec =
  group
    "test"
    "Named test suites"
    "Supported automated test commands."
    [ leaf
        "init"
        "Create prodbox.test.dhall"
        "Create the executable-sibling prodbox.test.dhall test-topology document."
        [flagOption "force" Nothing Nothing "Overwrite an existing prodbox.test.dhall"]
        [example ["test", "init"] "Create the test-topology document."]
    , leaf
        "run"
        "Run a topology-declared suite"
        "Run one topology-declared suite, or every suite with `all`, using .test-data isolation."
        coverageOptions
        [example ["test", "run", "unit"] "Run the topology-declared unit suite."]
    , leaf
        "all"
        "Run the full test suite"
        "Run lint and then the full test surface."
        coverageOptions
        [example ["test", "all"] "Run lint and the full test surface."]
    , leaf
        "lint"
        "Run lint and build checks"
        "Run the full lint surface plus a build."
        []
        [example ["test", "lint"] "Run lint and build checks."]
    , leaf
        "unit"
        "Run unit tests"
        "Run unit tests."
        coverageOptions
        [example ["test", "unit"] "Run unit tests."]
    , group
        "integration"
        "Run named integration suites"
        "Run named integration suites."
        [ integrationLeaf "all" "Run all integration suites"
        , integrationLeaf "cli" "Run CLI integration tests"
        , integrationLeaf "aws-iam" "Run AWS IAM integration tests"
        , integrationLeaf "dns-aws" "Run Route 53 integration tests"
        , integrationLeaf "aws-eks" "Run EKS integration tests"
        , integrationLeaf "env" "Run environment integration tests"
        , integrationLeaf "gateway-daemon" "Run gateway-daemon integration tests"
        , integrationLeaf "gateway-pods" "Run gateway pod integration tests"
        , integrationLeaf "gateway-partition" "Run gateway partition integration tests"
        , integrationLeaf "ha-rke2-aws" "Run HA RKE2 AWS integration tests"
        , integrationLeaf "lifecycle" "Run lifecycle integration tests"
        , integrationLeaf "pulumi" "Run Pulumi integration tests"
        , integrationLeaf "eks-volume-rebind" "Run retained-volume rebinding integration tests"
        , integrationLeaf "charts-storage" "Run chart-storage integration tests"
        , integrationLeaf "charts-platform" "Run chart-platform integration tests"
        , integrationLeaf "pulsar-broker" "Run Pulsar broker transport integration tests"
        , integrationLeaf "charts-vscode" "Run vscode stack integration tests"
        , integrationLeaf "charts-api" "Run API stack integration tests"
        , integrationLeaf "charts-websocket" "Run WebSocket stack integration tests"
        , integrationLeaf "admin-routes" "Run shared-host admin-route integration tests"
        , integrationLeaf "public-dns" "Run public DNS integration tests"
        , integrationLeaf "keycloak-invite" "Run Keycloak operator-invite integration tests"
        , integrationLeaf "sealed-vault" "Run sealed-Vault fail-closed integration tests"
        ]
        []
        [example ["test", "integration", "cli"] "Run the CLI integration suite."]
    ]
    []
    [example ["test", "all"] "Run the full supported test surface."]
 where
  coverageOptions =
    [ flagOption "coverage" Nothing Nothing "Enable coverage reporting for the selected test scope"
    , optionalOption "cov-fail-under" Nothing "INTEGER" "Require a minimum coverage percentage"
    , substrateOption
    ]
  integrationLeaf leafName leafSummary =
    leaf
      leafName
      leafSummary
      leafSummary
      coverageOptions
      [example ["test", "integration", leafName] ("Run the `" ++ leafName ++ "` integration suite.")]

substrateOption :: OptionSpec
substrateOption =
  optionalOption
    "substrate"
    Nothing
    "SUBSTRATE"
    "Target substrate (home-local, aws); default home-local"

nukeLeaf :: CommandSpec
nukeLeaf =
  leaf
    "nuke"
    "Total teardown of every prodbox-owned AWS resource (operator-only)"
    ( "The only sanctioned path to destroy long-lived shared "
        ++ "infrastructure (`aws-ses`, the long-lived `pulumi_state_backend` "
        ++ "bucket) transitively. TTY-only; refuses non-interactive contexts. "
        ++ "Requires the typed confirmation literal `NUKE EVERYTHING`. No "
        ++ "`--yes` shorthand by design. `--dry-run` renders the plan without "
        ++ "mutating any state."
    )
    [ flagOption "dry-run" Nothing Nothing "Render the teardown plan without mutating state"
    , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
    ]
    [ example ["nuke", "--dry-run"] "Render the total-teardown plan."
    ]

-- | @prodbox dev ...@ — developer + CI tooling, regrouped (Phase 5):
-- @dev check@ (was @check-code@), @dev lint ...@ (was @lint ...@),
-- @dev docs ...@ (was @docs ...@), and @dev tla-check@ (was @tla-check@).
devGroup :: CommandSpec
devGroup =
  group
    "dev"
    "Developer and CI tooling"
    "Local development and CI commands: the canonical quality gate, lint surfaces, generated-docs maintenance, and TLA+ checks."
    [ leaf
        "check"
        "Run policy, lint, and type checks"
        "Run the canonical quality gate."
        []
        [example ["dev", "check"] "Run the canonical quality gate."]
    , group
        "lint"
        "Doctrine lint surfaces"
        "Run doctrine-owned lint surfaces."
        [ leaf
            "all"
            "Run every lint surface"
            "Run every doctrine-owned lint surface."
            []
            [example ["dev", "lint", "all"] "Run every doctrine-owned lint surface."]
        , leaf
            "files"
            "Run repository-policy lint checks"
            "Check forbidden paths and library-first policy invariants."
            [flagOption "write" Nothing Nothing "Rewrite the target surface instead of only checking for drift"]
            [example ["dev", "lint", "files"] "Run repository-policy lint checks."]
        , leaf
            "docs"
            "Check generated documentation sections"
            "Check or rewrite marker-delimited documentation sections."
            [flagOption "write" Nothing Nothing "Rewrite the generated documentation sections"]
            [example ["dev", "lint", "docs"] "Check generated documentation sections for drift."]
        , leaf
            "haskell"
            "Run Haskell formatter and lint checks"
            "Run the formatter, hlint, and cabal-format consistency checks."
            [flagOption "write" Nothing Nothing "Rewrite Haskell formatting surfaces in place"]
            [example ["dev", "lint", "haskell"] "Run Haskell formatter and lint checks."]
        , leaf
            "chart"
            "Run Helm chart structural lint checks"
            "Run the Helm chart structural invariants linter."
            []
            [example ["dev", "lint", "chart"] "Run the Helm chart structural invariants linter."]
        ]
        []
        [example ["dev", "lint", "all"] "Run every doctrine-owned lint surface."]
    , group
        "docs"
        "Generated-documentation maintenance"
        "Check or regenerate marker-delimited documentation sections."
        [ leaf
            "check"
            "Check generated docs for drift"
            "Check marker-delimited documentation sections for drift."
            []
            [example ["dev", "docs", "check"] "Fail when generated documentation has drifted."]
        , leaf
            "generate"
            "Regenerate generated docs"
            "Rewrite marker-delimited documentation sections from their renderers."
            []
            [example ["dev", "docs", "generate"] "Regenerate marker-delimited documentation sections."]
        ]
        []
        [example ["dev", "docs", "check"] "Check generated documentation sections for drift."]
    , leaf
        "tla-check"
        "Run TLA+ checks"
        "Run the TLA+ model checks."
        []
        [example ["dev", "tla-check"] "Run the TLA+ model checks."]
    ]
    []
    [example ["dev", "check"] "Run the canonical quality gate."]

commandsLeaf :: CommandSpec
commandsLeaf =
  leaf
    "commands"
    "Render the command registry"
    "Render the command registry in plain text, tree, or JSON form."
    [ flagOption "tree" Nothing Nothing "Render the command registry as a tree"
    , flagOption "json" Nothing Nothing "Render the command registry as JSON"
    ]
    [ example ["commands"] "Render the command registry in plain-text form."
    , example ["commands", "--tree"] "Render the command registry as a tree."
    , example ["commands", "--json"] "Render the command registry as JSON."
    ]

helpLeaf :: CommandSpec
helpLeaf =
  leafWithArgs
    "help"
    "Render help for a command path"
    "Render detailed help for a registered command path."
    [repeatableArgument "command-path" "COMMAND_PATH" "Command path segments to render help for"]
    []
    [example ["help", "charts", "reconcile"] "Render detailed help for `prodbox charts reconcile`."]
