module Prodbox.CLI.Pulumi (
    runPulumiCommand,
)
where

import Prodbox.CLI.Command (PulumiCommand (..))
import Prodbox.Infra.AwsEksTestStack qualified as EksStack
import Prodbox.Infra.AwsTestStack qualified as TestStack
import System.Exit (ExitCode)

runPulumiCommand :: FilePath -> PulumiCommand -> IO ExitCode
runPulumiCommand repoRoot command =
    case command of
        PulumiEksResources -> EksStack.ensureAwsEksTestStackResources repoRoot
        PulumiEksDestroy _ -> EksStack.destroyAwsEksTestStack repoRoot
        PulumiTestResources -> TestStack.ensureAwsTestStackResources repoRoot
        PulumiTestDestroy _ -> TestStack.destroyAwsTestStack repoRoot
