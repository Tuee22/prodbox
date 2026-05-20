module Prodbox.CLI.Interactive
  ( InteractiveGuard (..)
  , allowNonTtyInteractiveEnvVar
  , awsCheckQuotasGuard
  , awsRequestQuotasGuard
  , awsSetupGuard
  , awsTeardownGuard
  , chartsDeleteGuard
  , configSetupGuard
  , renderNonTtyError
  , requireInteractiveTty
  )
where

import Prodbox.CLI.Output (writeDiagnosticLine)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hIsTerminalDevice, stdin)

-- | Test-only opt-in env var. Integration tests that exercise the
-- interactive surface with controlled stdin input set this to bypass
-- the TTY check. **Production agents must never set this.** Setting it
-- defeats the doctrine-required automation/operator-interactive split
-- documented in @documents/engineering/cli_command_surface.md@.
allowNonTtyInteractiveEnvVar :: String
allowNonTtyInteractiveEnvVar = "PRODBOX_ALLOW_NON_TTY_INTERACTIVE"

data InteractiveGuard = InteractiveGuard
  { guardCommand :: String
  , guardAutomationHint :: String
  }
  deriving (Eq, Show)

requireInteractiveTty :: InteractiveGuard -> IO ()
requireInteractiveTty guard = do
  isTty <- hIsTerminalDevice stdin
  bypass <- lookupEnv allowNonTtyInteractiveEnvVar
  case (isTty, bypass) of
    (True, _) -> pure ()
    (_, Just "1") -> pure ()
    _ -> do
      writeDiagnosticLine (renderNonTtyError guard)
      exitWith (ExitFailure 1)

renderNonTtyError :: InteractiveGuard -> String
renderNonTtyError guard =
  unlines
    [ guardCommand guard ++ " requires an interactive terminal but stdin is not a TTY."
    , ""
    , "For non-interactive automation (CI, agents, scripted workflows):"
    , guardAutomationHint guard
    , ""
    , "See documents/engineering/cli_command_surface.md "
        ++ "\"Interactive vs Non-Interactive Surfaces\"."
    ]

awsSetupGuard :: InteractiveGuard
awsSetupGuard =
  InteractiveGuard
    { guardCommand = "prodbox aws setup"
    , guardAutomationHint =
        unlines
          [ "  prodbox test all --substrate aws"
          , "  prodbox test integration <name> --substrate aws"
          , ""
          , "The suite-level IAM harness materializes operational aws.* from"
          , "aws_admin_for_test_simulation.* in prodbox-config.dhall and clears it"
          , "on suite exit. No prompt."
          ]
    }

awsTeardownGuard :: InteractiveGuard
awsTeardownGuard =
  InteractiveGuard
    { guardCommand = "prodbox aws teardown"
    , guardAutomationHint =
        unlines
          [ "The test-harness postflight auto-destroys per-run stacks and clears"
          , "aws.* on suite exit. For manual per-stack destroy:"
          , "  prodbox pulumi <stack>-destroy --yes"
          ]
    }

awsCheckQuotasGuard :: InteractiveGuard
awsCheckQuotasGuard =
  InteractiveGuard
    { guardCommand = "prodbox aws check-quotas"
    , guardAutomationHint =
        unlines
          [ "prodbox aws check-quotas is operator-only. Populate operational aws.*"
          , "first (via the test harness or by editing prodbox-config.dhall) and"
          , "re-run from a terminal."
          ]
    }

awsRequestQuotasGuard :: InteractiveGuard
awsRequestQuotasGuard =
  InteractiveGuard
    { guardCommand = "prodbox aws request-quotas"
    , guardAutomationHint =
        unlines
          [ "prodbox aws request-quotas is operator-only. Populate operational"
          , "aws.* first (via the test harness or by editing prodbox-config.dhall)"
          , "and re-run from a terminal."
          ]
    }

configSetupGuard :: InteractiveGuard
configSetupGuard =
  InteractiveGuard
    { guardCommand = "prodbox config setup"
    , guardAutomationHint =
        unlines
          [ "Edit prodbox-config.dhall directly against the"
          , "prodbox-config-types.dhall schema. The test harness reads it as-is."
          ]
    }

chartsDeleteGuard :: InteractiveGuard
chartsDeleteGuard =
  InteractiveGuard
    { guardCommand = "prodbox charts delete (interactive confirmation)"
    , guardAutomationHint =
        unlines
          [ "Pass --yes to skip the confirmation prompt:"
          , "  prodbox charts delete <chart> --yes"
          ]
    }
