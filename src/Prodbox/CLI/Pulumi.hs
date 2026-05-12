module Prodbox.CLI.Pulumi
  ( renderPulumiPlan
  , runPulumiCommand
  )
where

import Prodbox.CLI.Command
  ( PlanOptions (..)
  , PulumiCommand (..)
  )
import Prodbox.Infra.AwsEksTestStack qualified as EksStack
import Prodbox.Infra.AwsTestStack qualified as TestStack
import System.Exit
  ( ExitCode (ExitSuccess)
  )

runPulumiCommand :: FilePath -> PulumiCommand -> IO ExitCode
runPulumiCommand repoRoot command =
  case command of
    PulumiEksResources planOptions ->
      runPlanApply
        planOptions
        (renderPulumiPlan "eks-resources" False)
        (EksStack.ensureAwsEksTestStackResources repoRoot)
    PulumiEksDestroy summary planOptions ->
      runPlanApply
        planOptions
        (renderPulumiPlan "eks-destroy" summary)
        (EksStack.destroyAwsEksTestStack repoRoot summary)
    PulumiTestResources planOptions ->
      runPlanApply
        planOptions
        (renderPulumiPlan "test-resources" False)
        (TestStack.ensureAwsTestStackResources repoRoot)
    PulumiTestDestroy summary planOptions ->
      runPlanApply
        planOptions
        (renderPulumiPlan "test-destroy" summary)
        (TestStack.destroyAwsTestStack repoRoot summary)

runPlanApply :: PlanOptions -> String -> IO ExitCode -> IO ExitCode
runPlanApply planOptions renderedPlan applyAction = do
  maybePersistPlan (planFile planOptions) renderedPlan
  if dryRun planOptions
    then do
      putStr renderedPlan
      pure ExitSuccess
    else applyAction

renderPulumiPlan :: String -> Bool -> String
renderPulumiPlan commandName confirmed =
  unlines
    [ "PULUMI_PLAN"
    , "COMMAND=" ++ commandName
    , "CONFIRMED=" ++ if confirmed then "true" else "false"
    ]

maybePersistPlan :: Maybe FilePath -> String -> IO ()
maybePersistPlan Nothing _ = pure ()
maybePersistPlan (Just path) contents = writeFile path contents
