{-# LANGUAGE DuplicateRecordFields #-}

module Prodbox.CLI.Spec
  ( CommandSpec (..)
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
  , flag
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
  , GatewayCommand (..)
  , HostCommand (..)
  , IntegrationSuite (..)
  , K8sCommand (..)
  , LintCommand (..)
  , NativeCommand (..)
  , NukeOptions (..)
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

data CommandSpec = CommandSpec
  { name :: String
  , summary :: String
  , description :: String
  , children :: [CommandSpec]
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
        , checkCodeLeaf
        , commandsLeaf
        , configGroup
        , dnsGroup
        , docsGroup
        , gatewayGroup
        , helpLeaf
        , hostGroup
        , k8sGroup
        , lintGroup
        , nukeLeaf
        , pulumiGroup
        , rke2Group
        , testGroupSpec
        , tlaCheckLeaf
        , usersGroup
        , workloadGroup
        ]
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
    ["aws", "check-quotas"] -> Just (pure (RunNative (NativeAws AwsCheckQuotas)))
    ["aws", "request-quotas"] ->
      Just $
        fmap
          (RunNative . NativeAws . AwsRequestQuotas)
          (tierOptionParser PolicyFull "Quota target tier to request")
    ["charts", "list"] -> Just (pure (RunNative (NativeCharts ChartsList)))
    ["charts", "status"] ->
      Just (fmap (RunNative . NativeCharts . ChartsStatus) (strArgument (metavar "CHART")))
    ["charts", "deploy"] ->
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
    ["check-code"] -> Just (pure (RunNative NativeCheckCode))
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
    ["dns", "check"] -> Just (pure (RunNative (NativeDns DnsCheck)))
    ["docs", "check"] -> Just (pure (RunNative (NativeDocs DocsCheck)))
    ["docs", "generate"] -> Just (pure (RunNative (NativeDocs DocsGenerate)))
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
    ["host", "firewall"] -> Just (pure (RunNative (NativeHost HostFirewall)))
    ["host", "firewall", "gateway-restrict"] ->
      Just (RunNative . NativeHost . HostFirewallGatewayRestrict <$> gatewayNodePortParser)
    ["host", "firewall", "gateway-unrestrict"] ->
      Just (RunNative . NativeHost . HostFirewallGatewayUnrestrict <$> gatewayNodePortParser)
    ["host", "public-edge"] ->
      Just (fmap (RunNative . NativeHost . HostPublicEdge) substrateOptionParser)
    ["k8s", "health"] -> Just (pure (RunNative (NativeK8s K8sHealth)))
    ["k8s", "wait"] ->
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
    ["k8s", "logs"] ->
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
    ["lint", "all"] -> Just (pure (RunNative (NativeLint LintAll)))
    ["lint", "files"] -> Just (fmap (RunNative . NativeLint . LintFiles) writeSwitchParser)
    ["lint", "docs"] -> Just (fmap (RunNative . NativeLint . LintDocs) writeSwitchParser)
    ["lint", "haskell"] -> Just (fmap (RunNative . NativeLint . LintHaskell) writeSwitchParser)
    ["lint", "chart"] -> Just (pure (RunNative (NativeLint LintChart)))
    ["pulumi", "eks-resources"] ->
      Just (fmap (RunNative . NativePulumi . PulumiEksResources) planOptionsParser)
    ["pulumi", "eks-destroy"] ->
      Just $
        fmap
          (\(confirmed, planOptions') -> RunNative (NativePulumi (PulumiEksDestroy confirmed planOptions')))
          ((,) <$> yesSwitchParser "Skip confirmation prompts" <*> planOptionsParser)
    ["pulumi", "test-resources"] ->
      Just (fmap (RunNative . NativePulumi . PulumiTestResources) planOptionsParser)
    ["pulumi", "test-destroy"] ->
      Just $
        fmap
          (\(confirmed, planOptions') -> RunNative (NativePulumi (PulumiTestDestroy confirmed planOptions')))
          ((,) <$> yesSwitchParser "Skip confirmation prompts" <*> planOptionsParser)
    ["pulumi", "aws-subzone-resources"] ->
      Just (fmap (RunNative . NativePulumi . PulumiAwsSubzoneResources) planOptionsParser)
    ["pulumi", "aws-subzone-destroy"] ->
      Just $
        fmap
          ( \(confirmed, planOptions') ->
              RunNative (NativePulumi (PulumiAwsSubzoneDestroy confirmed planOptions'))
          )
          ((,) <$> yesSwitchParser "Skip confirmation prompts" <*> planOptionsParser)
    ["pulumi", "aws-ses-resources"] ->
      Just (fmap (RunNative . NativePulumi . PulumiAwsSesResources) planOptionsParser)
    ["pulumi", "aws-ses-destroy"] ->
      Just $
        fmap
          ( \(confirmed, planOptions') ->
              RunNative (NativePulumi (PulumiAwsSesDestroy confirmed planOptions'))
          )
          ((,) <$> yesSwitchParser "Skip confirmation prompts" <*> planOptionsParser)
    ["pulumi", "aws-ses-migrate-backend"] ->
      Just (fmap (RunNative . NativePulumi . PulumiAwsSesMigrateBackend) planOptionsParser)
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
    ["rke2", "status"] -> Just (pure (RunNative (NativeRke2 Rke2Status)))
    ["rke2", "start"] -> Just (pure (RunNative (NativeRke2 Rke2Start)))
    ["rke2", "stop"] -> Just (pure (RunNative (NativeRke2 Rke2Stop)))
    ["rke2", "restart"] -> Just (pure (RunNative (NativeRke2 Rke2Restart)))
    ["rke2", "reconcile"] ->
      Just (fmap (RunNative . NativeRke2 . Rke2Reconcile) planOptionsParser)
    ["rke2", "delete"] ->
      Just (rke2DeleteParser <$> rke2DeleteFlagsParser <*> planOptionsParser)
    ["rke2", "logs"] ->
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
    ["test", "integration", "charts-storage"] -> Just (withCoverage (TestIntegration IntegrationChartsStorage))
    ["test", "integration", "charts-platform"] -> Just (withCoverage (TestIntegration IntegrationChartsPlatform))
    ["test", "integration", "charts-vscode"] -> Just (withCoverage (TestIntegration IntegrationChartsVscode))
    ["test", "integration", "charts-api"] -> Just (withCoverage (TestIntegration IntegrationChartsApi))
    ["test", "integration", "charts-websocket"] -> Just (withCoverage (TestIntegration IntegrationChartsWebsocket))
    ["test", "integration", "admin-routes"] -> Just (withCoverage (TestIntegration IntegrationAdminRoutes))
    ["test", "integration", "public-dns"] -> Just (withCoverage (TestIntegration IntegrationPublicDns))
    ["test", "integration", "keycloak-invite"] -> Just (withCoverage (TestIntegration IntegrationKeycloakInvite))
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
    ["tla-check"] -> Just (pure (RunNative NativeTlaCheck))
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

foregroundParser :: Parser Bool
foregroundParser =
  flag
    True
    True
    ( long "foreground"
        <> help "Run in the foreground"
    )

withCoverage :: TestScope -> Parser CommandRequest
withCoverage scope =
  (\coverage substrate -> RunNative (NativeTest (TestCommand scope coverage substrate)))
    <$> coverageFlagsParser
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
    <*> optional
      ( strOption
          ( long "log-level"
              <> metavar "LEVEL"
              <> help "Override daemon log level"
          )
      )
    <*> optional
      ( option
          auto
          ( long "port"
              <> metavar "INTEGER"
              <> help "Override daemon port"
          )
      )
    <*> foregroundParser
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
          ( long "log-level"
              <> metavar "LEVEL"
              <> help "Override daemon log level"
          )
      )
    <*> optional
      ( option
          auto
          ( long "port"
              <> metavar "INTEGER"
              <> help "Override daemon port"
          )
      )
    <*> foregroundParser

writeSwitchParser :: Parser Bool
writeSwitchParser =
  switch
    ( long "write"
        <> help "Rewrite the target surface instead of only checking for drift"
    )

yesSwitchParser :: String -> Parser Bool
yesSwitchParser helpText =
  switch
    ( long "yes"
        <> short 'y'
        <> help helpText
    )

-- | Sprint 4.11: parser for the @prodbox rke2 delete@ flag matrix.
-- @--yes@ is independent; @--cascade@ and @--allow-pulumi-residue@
-- are mutually exclusive (enforced via 'flag'' + '<|>' so the second
-- flag's appearance produces a parse-time error when the first has
-- already consumed its match). The default (neither cascade nor
-- allow-pulumi-residue) is the refuse-on-per-run-residue path.
rke2DeleteFlagsParser :: Parser Rke2DeleteFlags
rke2DeleteFlagsParser =
  buildFlags
    <$> yesSwitchParser "Confirm full RKE2 cluster deletion"
    <*> ( flag'
            CascadeMode
            ( long "cascade"
                <> help
                  ( "Orchestrate the full teardown — K8s drain, per-run "
                      ++ "Pulumi destroys, cluster uninstall, postflight "
                      ++ "tag sweep — as one atomic operator action. The "
                      ++ "K8s drain phase skips gracefully when no cluster "
                      ++ "is reachable. Mutually exclusive with "
                      ++ "--allow-pulumi-residue."
                  )
            )
            <|> flag'
              AllowResidueMode
              ( long "allow-pulumi-residue"
                  <> help
                    ( "Bypass the per-run Pulumi residue refuse-path "
                        ++ "(recovery only). Allows uninstalling RKE2 even "
                        ++ "while aws-eks / aws-eks-subzone / aws-test "
                        ++ "stacks still have live resources. Mutually "
                        ++ "exclusive with --cascade."
                    )
              )
            <|> pure RefuseMode
        )
 where
  buildFlags confirmed mode =
    Rke2DeleteFlags
      { rke2DeleteYes = confirmed
      , rke2DeleteCascade = mode == CascadeMode
      , rke2DeleteAllowPulumiResidue = mode == AllowResidueMode
      }

data Rke2DeleteMode
  = RefuseMode
  | CascadeMode
  | AllowResidueMode
  deriving (Eq, Show)

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
                  ( "Run `prodbox pulumi <stack>-destroy --yes` for each "
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

example :: [String] -> String -> Example
example = Example

leaf :: String -> String -> String -> [OptionSpec] -> [Example] -> CommandSpec
leaf nodeName nodeSummary nodeDescription nodeOptions nodeExamples =
  CommandSpec
    { name = nodeName
    , summary = nodeSummary
    , description = nodeDescription
    , children = []
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
        "Delete the operational IAM user. Default mode opens with a Pulumi-residue check and refuses if any AWS substrate stack (`aws-eks`, `aws-eks-subzone`, `aws-test`, `aws-ses`) still owns live resources. `--destroy-pulumi-residue` orchestrates `prodbox pulumi <stack>-destroy --yes` in canonical order before deleting the operational IAM user; destroying the long-lived `aws-ses` stack triggers a 5-30 min SES re-verification and ~24h S3 bucket-name cooldown. `--allow-pulumi-residue` is the operator-acknowledged recovery escape hatch that bypasses the residue check entirely (stacks become orphaned). `--destroy-pulumi-residue` and `--allow-pulumi-residue` are mutually exclusive at parse time."
        [ flagOption "dry-run" Nothing Nothing "Render the IAM teardown plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        , flagOption
            "destroy-pulumi-residue"
            Nothing
            Nothing
            "Run `prodbox pulumi <stack>-destroy --yes` for each live Pulumi-managed AWS stack in canonical order before deleting the operational IAM user (mutually exclusive with --allow-pulumi-residue)"
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
    , leaf
        "check-quotas"
        "Inspect supported AWS quotas"
        "Inspect supported AWS quotas."
        []
        [example ["aws", "check-quotas"] "Inspect AWS quotas."]
    , leaf
        "request-quotas"
        "Request supported AWS quotas"
        "Request supported AWS quota increases."
        [optionalOption "tier" Nothing "TIER" "Quota target tier to request"]
        [example ["aws", "request-quotas", "--tier", "core"] "Request core-tier quota increases."]
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
        "Inspect or install host firewall rules"
        "Inspect required firewall rules; subcommands install gateway-NodePort restrictions."
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
        [example ["host", "firewall"] "Inspect firewall expectations."]
    , leaf
        "public-edge"
        "Check public DNS/TLS edge state"
        "Inspect Route 53, certificate, and shared-host readiness."
        [substrateOption]
        [ example ["host", "public-edge"] "Inspect public-edge readiness (home substrate)."
        , example
            ["host", "public-edge", "--substrate", "aws"]
            "Inspect public-edge readiness on the AWS substrate."
        ]
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

k8sGroup :: CommandSpec
k8sGroup =
  group
    "k8s"
    "Kubernetes helpers"
    "Kubernetes health and log utilities."
    [ leaf
        "health"
        "Check cluster health"
        "Inspect Kubernetes health."
        []
        [example ["k8s", "health"] "Inspect cluster health."]
    , leaf
        "wait"
        "Wait for deployments to be ready"
        "Wait for named namespaces to become ready."
        [ optionalOption "timeout" (Just 't') "INTEGER" "Timeout in seconds"
        , optionalOption "namespace" (Just 'n') "VALUE" "Namespace to wait for"
        ]
        [example ["k8s", "wait", "--timeout", "300"] "Wait for infrastructure workloads."]
    , leaf
        "logs"
        "Show recent infrastructure logs"
        "Show recent logs from infrastructure namespaces."
        [ optionalOption "namespace" (Just 'n') "VALUE" "Namespace to get logs from"
        , optionalOption "tail" Nothing "INTEGER" "Number of log lines per container"
        ]
        [example ["k8s", "logs", "--tail", "25"] "Show recent infrastructure logs."]
    ]
    []
    [example ["k8s", "health"] "Check Kubernetes health."]

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
        , optionalOption "log-level" Nothing "LEVEL" "Override daemon log level"
        , optionalOption "port" Nothing "INTEGER" "Override daemon port"
        , flagOption "foreground" Nothing Nothing "Run in the foreground"
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
    , leaf
        "config-gen"
        "Generate gateway config"
        "Generate a gateway config template."
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
    [ leaf
        "invite"
        "Invite an operator-owned user by email"
        "Create a Keycloak user with emailVerified=false and trigger the SES-backed invite email."
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
    , leaf
        "revoke"
        "Disable or delete an operator-managed user"
        "Revoke an operator-managed user. Disables the user by default; pass --delete to fully remove the user."
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
        [ optionalOption "log-level" Nothing "LEVEL" "Override daemon log level"
        , optionalOption "port" Nothing "INTEGER" "Override daemon port"
        , flagOption "foreground" Nothing Nothing "Run in the foreground"
        ]
        [example ["workload", "start", "--foreground"] "Start the workload runtime in the foreground."]
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
    , leaf
        "status"
        "Show detailed chart status"
        "Inspect the current state of a root chart."
        []
        [example ["charts", "status", "vscode"] "Inspect the vscode chart status."]
    , leaf
        "deploy"
        "Deploy a root chart stack"
        "Reconcile a root chart to the supported state."
        [ flagOption "dry-run" Nothing Nothing "Render the deployment plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        , optionalOption
            "substrate"
            Nothing
            "SUBSTRATE"
            "Target substrate (home-local, aws); default home-local"
        ]
        [ example ["charts", "deploy", "vscode"] "Deploy the vscode stack."
        , example ["charts", "deploy", "--dry-run", "vscode"] "Render the chart deployment plan."
        ]
    , leaf
        "delete"
        "Delete a root chart stack"
        "Delete a root chart stack."
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

pulumiGroup :: CommandSpec
pulumiGroup =
  group
    "pulumi"
    "AWS validation stack lifecycle"
    "Pulumi-backed AWS validation stack commands."
    [ leaf
        "eks-resources"
        "Provision or inspect EKS test stack"
        "Reconcile the EKS validation stack."
        [ flagOption "dry-run" Nothing Nothing "Render the Pulumi plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [example ["pulumi", "eks-resources"] "Reconcile the EKS validation stack."]
    , leaf
        "eks-destroy"
        "Destroy EKS test stack"
        "Destroy the EKS validation stack."
        [ flagOption "yes" (Just 'y') Nothing "Skip confirmation prompts"
        , flagOption "dry-run" Nothing Nothing "Render the destroy plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [example ["pulumi", "eks-destroy", "--yes"] "Destroy the EKS validation stack."]
    , leaf
        "test-resources"
        "Provision or inspect HA RKE2 test stack"
        "Reconcile the HA RKE2 validation stack."
        [ flagOption "dry-run" Nothing Nothing "Render the Pulumi plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [example ["pulumi", "test-resources"] "Reconcile the HA RKE2 validation stack."]
    , leaf
        "test-destroy"
        "Destroy HA RKE2 test stack"
        "Destroy the HA RKE2 validation stack."
        [ flagOption "yes" (Just 'y') Nothing "Skip confirmation prompts"
        , flagOption "dry-run" Nothing Nothing "Render the destroy plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [example ["pulumi", "test-destroy", "--yes"] "Destroy the HA RKE2 validation stack."]
    , leaf
        "aws-subzone-resources"
        "Provision the per-substrate Route 53 subzone"
        "Reconcile the AWS-substrate Route 53 hosted subzone and NS delegation."
        [ flagOption "dry-run" Nothing Nothing "Render the subzone plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [example ["pulumi", "aws-subzone-resources"] "Reconcile the AWS-substrate Route 53 subzone."]
    , leaf
        "aws-subzone-destroy"
        "Destroy the per-substrate Route 53 subzone"
        "Destroy the AWS-substrate Route 53 hosted subzone and remove the parent NS delegation."
        [ flagOption "yes" (Just 'y') Nothing "Skip confirmation prompts"
        , flagOption "dry-run" Nothing Nothing "Render the destroy plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [example ["pulumi", "aws-subzone-destroy", "--yes"] "Destroy the AWS-substrate Route 53 subzone."]
    , leaf
        "aws-ses-resources"
        "Provision cross-substrate AWS SES infrastructure"
        "Reconcile the shared AWS SES sending identity, receive subdomain, receive rule set, S3 capture bucket, and SMTP IAM user used by Phase 8 operator-invited email auth."
        [ flagOption "dry-run" Nothing Nothing "Render the SES plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [example ["pulumi", "aws-ses-resources"] "Reconcile the cross-substrate SES infrastructure."]
    , leaf
        "aws-ses-destroy"
        "Destroy cross-substrate AWS SES infrastructure"
        "Destroy the shared AWS SES stack (sending identity, receive subdomain, receive rule set, S3 capture bucket, and SMTP IAM user)."
        [ flagOption "yes" (Just 'y') Nothing "Skip confirmation prompts"
        , flagOption "dry-run" Nothing Nothing "Render the destroy plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [example ["pulumi", "aws-ses-destroy", "--yes"] "Destroy the cross-substrate SES infrastructure."]
    , leaf
        "aws-ses-migrate-backend"
        "Migrate aws-ses Pulumi state onto the long-lived S3 backend"
        "Operator-interactive command: migrate the `aws-ses` stack's Pulumi state from the in-cluster MinIO backend onto the dedicated long-lived S3 bucket named by `pulumi_state_backend` in `prodbox-config.dhall`. Idempotent; no-op when the stack already lives in the long-lived backend. TTY-only; refuses non-interactive contexts."
        [ flagOption "dry-run" Nothing Nothing "Render the migration plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [ example
            ["pulumi", "aws-ses-migrate-backend"]
            "Migrate aws-ses state onto the long-lived S3 backend."
        ]
    ]
    []
    [example ["pulumi", "eks-resources"] "Reconcile the EKS validation stack."]

rke2Group :: CommandSpec
rke2Group =
  group
    "rke2"
    "Local cluster lifecycle"
    "Local cluster lifecycle commands."
    [ leaf
        "status"
        "Check RKE2 status"
        "Inspect the local cluster status."
        []
        [example ["rke2", "status"] "Inspect RKE2 status."]
    , leaf
        "start"
        "Start RKE2"
        "Start the local cluster service."
        []
        [example ["rke2", "start"] "Start RKE2."]
    , leaf "stop" "Stop RKE2" "Stop the local cluster service." [] [example ["rke2", "stop"] "Stop RKE2."]
    , leaf
        "restart"
        "Restart RKE2"
        "Restart the local cluster service."
        []
        [example ["rke2", "restart"] "Restart RKE2."]
    , leaf
        "reconcile"
        "Reconcile RKE2"
        "Reconcile the supported local cluster state."
        [ flagOption "dry-run" Nothing Nothing "Render the lifecycle plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [ example ["rke2", "reconcile"] "Reconcile the supported local cluster."
        , example ["rke2", "reconcile", "--dry-run"] "Render the lifecycle plan."
        ]
    , leaf
        "delete"
        "Delete RKE2"
        "Delete the local cluster. Default mode opens with a per-run-residue check and refuses if `aws-eks`, `aws-eks-subzone`, or `aws-test` still have live resources. `--cascade` orchestrates the full teardown (K8s drain + per-run Pulumi destroys + cluster uninstall + postflight tag sweep) as one atomic operator action; the K8s drain phase skips gracefully when no cluster is reachable. `--allow-pulumi-residue` bypasses the residue check for operator-acknowledged recovery scenarios. `--cascade` and `--allow-pulumi-residue` are mutually exclusive at parse time."
        [ flagOption "yes" (Just 'y') Nothing "Confirm full RKE2 cluster deletion"
        , flagOption
            "cascade"
            Nothing
            Nothing
            "Orchestrate the full teardown (K8s drain + per-run Pulumi destroys + cluster uninstall + postflight tag sweep) as one atomic operator action"
        , flagOption
            "allow-pulumi-residue"
            Nothing
            Nothing
            "Bypass the per-run Pulumi residue refuse-path (recovery only)"
        , flagOption "dry-run" Nothing Nothing "Render the delete plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [ example
            ["rke2", "delete", "--yes"]
            "Delete the local cluster (refuses if per-run Pulumi stacks are live)."
        , example
            ["rke2", "delete", "--yes", "--cascade"]
            "Orchestrate the full teardown as one atomic operator action."
        ]
    , leaf
        "logs"
        "Show RKE2 logs"
        "Show RKE2 service logs."
        [optionalOption "lines" (Just 'n') "INTEGER" "Number of log lines to show"]
        [example ["rke2", "logs", "--lines", "50"] "Show recent RKE2 logs."]
    ]
    []
    [example ["rke2", "reconcile"] "Reconcile the supported local cluster state."]

testGroupSpec :: CommandSpec
testGroupSpec =
  group
    "test"
    "Named test suites"
    "Supported automated test commands."
    [ leaf
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
        , integrationLeaf "charts-storage" "Run chart-storage integration tests"
        , integrationLeaf "charts-platform" "Run chart-platform integration tests"
        , integrationLeaf "charts-vscode" "Run vscode stack integration tests"
        , integrationLeaf "charts-api" "Run API stack integration tests"
        , integrationLeaf "charts-websocket" "Run WebSocket stack integration tests"
        , integrationLeaf "admin-routes" "Run shared-host admin-route integration tests"
        , integrationLeaf "public-dns" "Run public DNS integration tests"
        , integrationLeaf "keycloak-invite" "Run Keycloak operator-invite integration tests"
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

checkCodeLeaf :: CommandSpec
checkCodeLeaf =
  leaf
    "check-code"
    "Run policy, lint, and type checks"
    "Run the canonical quality gate."
    []
    [example ["check-code"] "Run the canonical quality gate."]

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
  leaf
    "help"
    "Render help for a command path"
    "Render detailed help for a registered command path."
    []
    [example ["help", "charts", "deploy"] "Render detailed help for `prodbox charts deploy`."]

tlaCheckLeaf :: CommandSpec
tlaCheckLeaf =
  leaf
    "tla-check"
    "Run TLA+ checks"
    "Run the TLA+ model checks."
    []
    [example ["tla-check"] "Run the TLA+ model checks."]

docsGroup :: CommandSpec
docsGroup =
  group
    "docs"
    "Generated-documentation maintenance"
    "Check or regenerate marker-delimited documentation sections."
    [ leaf
        "check"
        "Check generated docs for drift"
        "Check marker-delimited documentation sections for drift."
        []
        [example ["docs", "check"] "Fail when generated documentation has drifted."]
    , leaf
        "generate"
        "Regenerate generated docs"
        "Rewrite marker-delimited documentation sections from their renderers."
        []
        [example ["docs", "generate"] "Regenerate marker-delimited documentation sections."]
    ]
    []
    [example ["docs", "check"] "Check generated documentation sections for drift."]

lintGroup :: CommandSpec
lintGroup =
  group
    "lint"
    "Doctrine lint surfaces"
    "Run doctrine-owned lint surfaces."
    [ leaf
        "all"
        "Run every lint surface"
        "Run every doctrine-owned lint surface."
        []
        [example ["lint", "all"] "Run every doctrine-owned lint surface."]
    , leaf
        "files"
        "Run repository-policy lint checks"
        "Check forbidden paths and library-first policy invariants."
        [flagOption "write" Nothing Nothing "Rewrite the target surface instead of only checking for drift"]
        [example ["lint", "files"] "Run repository-policy lint checks."]
    , leaf
        "docs"
        "Check generated documentation sections"
        "Check or rewrite marker-delimited documentation sections."
        [flagOption "write" Nothing Nothing "Rewrite the generated documentation sections"]
        [example ["lint", "docs"] "Check generated documentation sections for drift."]
    , leaf
        "haskell"
        "Run Haskell formatter and lint checks"
        "Run the formatter, hlint, and cabal-format consistency checks."
        [flagOption "write" Nothing Nothing "Rewrite Haskell formatting surfaces in place"]
        [example ["lint", "haskell"] "Run Haskell formatter and lint checks."]
    , leaf
        "chart"
        "Run Helm chart structural lint checks"
        "Run the Helm chart structural invariants linter."
        []
        [example ["lint", "chart"] "Run the Helm chart structural invariants linter."]
    ]
    []
    [example ["lint", "all"] "Run every doctrine-owned lint surface."]
