module Prodbox.CLI.Spec
  ( CommandListingFormat (..)
  , CommandSpec (..)
  , Example (..)
  , OptionSpec (..)
  , commandRegistry
  , findCommandSpec
  , leafCommandPaths
  )
where

import Data.List (find)

data Example = Example
  { exampleCommand :: [String]
  , exampleDescription :: String
  }
  deriving (Eq, Show)

data OptionSpec = OptionSpec
  { longName :: String
  , shortName :: Maybe Char
  , metavar :: Maybe String
  , optionDescription :: String
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

data CommandListingFormat
  = CommandsPlain
  | CommandsTree
  | CommandsJson
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
        , configGroup
        , dnsGroup
        , gatewayGroup
        , hostGroup
        , k8sGroup
        , pulumiGroup
        , rke2Group
        , testGroupSpec
        , tlaCheckLeaf
        , workloadGroup
        ]
    , options =
        [ flag "verbose" (Just 'v') Nothing "Enable verbose output"
        , flag "version" Nothing Nothing "Show version"
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

flag :: String -> Maybe Char -> Maybe String -> String -> OptionSpec
flag long shortName' metavar' helpText =
  OptionSpec
    { longName = long
    , shortName = shortName'
    , metavar = metavar'
    , optionDescription = helpText
    , required = False
    }

requiredOption :: String -> Maybe Char -> String -> String -> OptionSpec
requiredOption long shortName' metavar' helpText =
  OptionSpec
    { longName = long
    , shortName = shortName'
    , metavar = Just metavar'
    , optionDescription = helpText
    , required = True
    }

optionalOption :: String -> Maybe Char -> String -> String -> OptionSpec
optionalOption long shortName' metavar' helpText =
  OptionSpec
    { longName = long
    , shortName = shortName'
    , metavar = Just metavar'
    , optionDescription = helpText
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
        []
        [example ["config", "setup"] "Create or refresh the config interactively."]
    , leaf
        "show"
        "Display current config"
        "Render the decoded config with secrets masked by default."
        [flag "show-secrets" Nothing Nothing "Show full secret values"]
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
        [optionalOption "tier" Nothing "TIER" "Operational IAM policy tier to provision"]
        [example ["aws", "setup", "--tier", "full"] "Create or refresh the operational IAM user."]
    , leaf
        "teardown"
        "Delete operational IAM user"
        "Delete the operational IAM user."
        []
        [example ["aws", "teardown"] "Delete the operational IAM user."]
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
    , leaf
        "firewall"
        "Check firewall requirements"
        "Inspect required firewall rules."
        []
        [example ["host", "firewall"] "Inspect firewall expectations."]
    , leaf
        "public-edge"
        "Check public DNS/TLS edge state"
        "Inspect Route 53, certificate, and shared-host readiness."
        []
        [example ["host", "public-edge"] "Inspect public-edge readiness."]
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
        [ requiredOption "config" Nothing "PATH" "Gateway config path"
        , optionalOption "log-level" Nothing "LEVEL" "Override daemon log level"
        , optionalOption "port" Nothing "INTEGER" "Override daemon port"
        , flag "foreground" Nothing Nothing "Run in the foreground"
        ]
        [example ["gateway", "start", "--config", "gateway.dhall"] "Start the gateway daemon."]
    , leaf
        "status"
        "Query gateway daemon status"
        "Query the gateway daemon status surface."
        [requiredOption "config" Nothing "PATH" "Gateway config path"]
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
        , flag "foreground" Nothing Nothing "Run in the foreground"
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
        [ flag "dry-run" Nothing Nothing "Render the deployment plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [ example ["charts", "deploy", "vscode"] "Deploy the vscode stack."
        , example ["charts", "deploy", "--dry-run", "vscode"] "Render the chart deployment plan."
        ]
    , leaf
        "delete"
        "Delete a root chart stack"
        "Delete a root chart stack."
        [ flag "yes" (Just 'y') Nothing "Skip confirmation prompt"
        , flag "dry-run" Nothing Nothing "Render the deletion plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
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
        [ flag "dry-run" Nothing Nothing "Render the Pulumi plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [example ["pulumi", "eks-resources"] "Reconcile the EKS validation stack."]
    , leaf
        "eks-destroy"
        "Destroy EKS test stack"
        "Destroy the EKS validation stack."
        [ flag "yes" (Just 'y') Nothing "Skip confirmation prompts"
        , flag "dry-run" Nothing Nothing "Render the destroy plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [example ["pulumi", "eks-destroy", "--yes"] "Destroy the EKS validation stack."]
    , leaf
        "test-resources"
        "Provision or inspect HA RKE2 test stack"
        "Reconcile the HA RKE2 validation stack."
        [ flag "dry-run" Nothing Nothing "Render the Pulumi plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [example ["pulumi", "test-resources"] "Reconcile the HA RKE2 validation stack."]
    , leaf
        "test-destroy"
        "Destroy HA RKE2 test stack"
        "Destroy the HA RKE2 validation stack."
        [ flag "yes" (Just 'y') Nothing "Skip confirmation prompts"
        , flag "dry-run" Nothing Nothing "Render the destroy plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [example ["pulumi", "test-destroy", "--yes"] "Destroy the HA RKE2 validation stack."]
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
        [ flag "dry-run" Nothing Nothing "Render the lifecycle plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [ example ["rke2", "reconcile"] "Reconcile the supported local cluster."
        , example ["rke2", "reconcile", "--dry-run"] "Render the lifecycle plan."
        ]
    , leaf
        "install"
        "Deprecated alias for reconcile"
        "Deprecated alias for `prodbox rke2 reconcile`."
        [ flag "dry-run" Nothing Nothing "Render the lifecycle plan without mutating state"
        , optionalOption "plan-file" Nothing "PATH" "Write the rendered plan to a file"
        ]
        [example ["rke2", "install"] "Use the one-cycle reconcile alias."]
    , leaf
        "delete"
        "Delete RKE2"
        "Delete the local cluster."
        [flag "yes" (Just 'y') Nothing "Confirm full RKE2 cluster deletion"]
        [example ["rke2", "delete", "--yes"] "Delete the local cluster."]
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
        ]
        []
        [example ["test", "integration", "cli"] "Run the CLI integration suite."]
    ]
    []
    [example ["test", "all"] "Run the full supported test surface."]
 where
  coverageOptions =
    [ flag "coverage" Nothing Nothing "Enable coverage reporting for the selected test scope"
    , optionalOption "cov-fail-under" Nothing "INTEGER" "Require a minimum coverage percentage"
    ]
  integrationLeaf leafName leafSummary =
    leaf
      leafName
      leafSummary
      leafSummary
      coverageOptions
      [example ["test", "integration", leafName] ("Run the `" ++ leafName ++ "` integration suite.")]

checkCodeLeaf :: CommandSpec
checkCodeLeaf =
  leaf
    "check-code"
    "Run policy, lint, and type checks"
    "Run the canonical quality gate."
    []
    [example ["check-code"] "Run the canonical quality gate."]

tlaCheckLeaf :: CommandSpec
tlaCheckLeaf =
  leaf
    "tla-check"
    "Run TLA+ checks"
    "Run the TLA+ model checks."
    []
    [example ["tla-check"] "Run the TLA+ model checks."]
