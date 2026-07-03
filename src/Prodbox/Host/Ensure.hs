module Prodbox.Host.Ensure
  ( HostReconcileAction (..)
  , HostReconcileDecision (..)
  , HostReconcileStep (..)
  , HostReconciler (..)
  , HostProviderState (..)
  , ensureIncus
  , ensureLima
  , ensureWsl2
  , hostProviderReconciler
  , hostReconcilerDecision
  , hostReconcilerPlan
  , reconcilerApplies
  )
where

import Prodbox.Host.Substrate (HostSubstrate (..))

data HostReconcileAction
  = ProbeTool String
  | InstallHint String
  | VerifyTool String
  deriving (Eq, Show)

data HostReconcileStep = HostReconcileStep
  { hostReconcileStepLabel :: String
  , hostReconcileStepAction :: HostReconcileAction
  }
  deriving (Eq, Show)

data HostProviderState
  = HostProviderReady
  | HostProviderMissing
  | HostProviderRequiresReboot String
  deriving (Eq, Show)

data HostReconcileDecision
  = HostReconcileNoop
  | HostReconcileApply [HostReconcileStep]
  | HostReconcileRebootRequired String
  deriving (Eq, Show)

data HostReconciler = HostReconciler
  { hostReconcilerName :: String
  , hostReconcilerAppliesTo :: HostSubstrate -> Bool
  , hostReconcilerSteps :: [HostReconcileStep]
  }

reconcilerApplies :: HostReconciler -> HostSubstrate -> Bool
reconcilerApplies reconciler =
  hostReconcilerAppliesTo reconciler

hostReconcilerPlan :: HostReconciler -> HostSubstrate -> Either String [HostReconcileStep]
hostReconcilerPlan reconciler substrate
  | reconcilerApplies reconciler substrate = Right (hostReconcilerSteps reconciler)
  | otherwise =
      Left
        ( hostReconcilerName reconciler
            ++ " does not apply to "
            ++ show substrate
        )

hostReconcilerDecision
  :: HostReconciler
  -> HostSubstrate
  -> HostProviderState
  -> Either String HostReconcileDecision
hostReconcilerDecision reconciler substrate state = do
  steps <- hostReconcilerPlan reconciler substrate
  pure $
    case state of
      HostProviderReady -> HostReconcileNoop
      HostProviderMissing -> HostReconcileApply steps
      HostProviderRequiresReboot reason -> HostReconcileRebootRequired reason

hostProviderReconciler :: HostSubstrate -> HostReconciler
hostProviderReconciler substrate =
  case substrate of
    AppleSilicon -> ensureLima
    WindowsCpu -> ensureWsl2
    WindowsGpu -> ensureWsl2
    LinuxCpu -> ensureIncus
    LinuxGpu -> ensureIncus

ensureLima :: HostReconciler
ensureLima =
  HostReconciler
    { hostReconcilerName = "lima"
    , hostReconcilerAppliesTo = (== AppleSilicon)
    , hostReconcilerSteps =
        [ HostReconcileStep "probe limactl" (ProbeTool "limactl")
        , HostReconcileStep
            "install Lima"
            (InstallHint "Install Lima and create the prodbox Ubuntu 24.04 VM.")
        , HostReconcileStep "verify limactl" (VerifyTool "limactl")
        ]
    }

ensureWsl2 :: HostReconciler
ensureWsl2 =
  HostReconciler
    { hostReconcilerName = "wsl2"
    , hostReconcilerAppliesTo = \substrate -> substrate == WindowsCpu || substrate == WindowsGpu
    , hostReconcilerSteps =
        [ HostReconcileStep "probe wsl" (ProbeTool "wsl")
        , HostReconcileStep
            "install WSL2"
            (InstallHint "Enable WSL2 and install the prodbox Ubuntu 24.04 distro.")
        , HostReconcileStep "verify wsl" (VerifyTool "wsl")
        ]
    }

ensureIncus :: HostReconciler
ensureIncus =
  HostReconciler
    { hostReconcilerName = "incus"
    , hostReconcilerAppliesTo = \substrate -> substrate == LinuxCpu || substrate == LinuxGpu
    , hostReconcilerSteps =
        [ HostReconcileStep "probe incus" (ProbeTool "incus")
        , HostReconcileStep
            "install Incus"
            (InstallHint "Install Incus if a nested Linux VM frame is required.")
        , HostReconcileStep "verify incus" (VerifyTool "incus")
        ]
    }
