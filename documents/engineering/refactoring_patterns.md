# Refactoring Patterns

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: README.md, CLAUDE.md, documents/engineering/README.md

> **Purpose**: Show repository-safe before or after patterns for moving imperative or stringly
> logic toward the Haskell functional style used by `prodbox`.

## 1. Raw String Command Routing -> ADT Routing

### Before

```haskell
runAction :: String -> IO ExitCode
runAction action =
    case action of
        "install" -> runInstall
        "delete" -> runDelete
        "status" -> runStatus
        _ -> failWith "unknown action"
```

### After

```haskell
data Action
    = ActionInstall
    | ActionDelete ConfirmedDelete
    | ActionStatus
    deriving (Eq, Show)

runAction :: Action -> IO ExitCode
runAction action =
    case action of
        ActionInstall -> runInstall
        ActionDelete confirmed -> runDelete confirmed
        ActionStatus -> runStatus
```

Parse external text once. Do not keep the rest of the runtime on raw command strings.

## 2. Mixed Planning and Execution -> Pure Planner Plus Boundary Runner

### Before

```haskell
ensureNamespace :: FilePath -> String -> IO ExitCode
ensureNamespace repoRoot namespace = do
    let args = ["create", "namespace", namespace]
    runCommand
        CommandSpec
            { commandPath = "kubectl",
              commandArguments = args,
              commandEnvironment = Nothing,
              commandWorkingDirectory = Just repoRoot
            }
```

### After

```haskell
buildCreateNamespacePlan :: String -> Plan String
buildCreateNamespacePlan namespace =
    buildPlan
        (\name -> "CREATE_NAMESPACE\nNAME=" ++ name ++ "\n")
        namespace

applyCreateNamespacePlan :: FilePath -> String -> IO ExitCode
applyCreateNamespacePlan repoRoot namespace =
    runCommand
        Subprocess
            { subprocessPath = "kubectl",
              subprocessArguments = ["create", "namespace", namespace],
              subprocessEnvironment = Nothing,
              subprocessWorkingDirectory = Just repoRoot
            }

ensureNamespace :: FilePath -> PlanOptions -> String -> IO ExitCode
ensureNamespace repoRoot options namespace =
    runPlanWithOptions
        options
        (buildCreateNamespacePlan namespace)
        (applyCreateNamespacePlan repoRoot)
```

The command keeps a pure plan builder, a focused apply boundary, and one shared dry-run or
plan-file runner.

## 3. Ad-Hoc Validation -> Decode Then Execute

### Before

```haskell
runDnsCheck :: String -> IO ExitCode
runDnsCheck fqdn =
    if '.' `elem` fqdn
        then performDnsCheck fqdn
        else failWith "invalid fqdn"
```

### After

```haskell
newtype Fqdn = Fqdn { unFqdn :: String }

parseFqdn :: String -> Either String Fqdn
parseFqdn raw =
    case splitOn "." raw of
        labels | length labels >= 2 && all (/= "") labels -> Right (Fqdn raw)
        _ -> Left ("invalid fqdn: " ++ raw)

runDnsCheck :: String -> IO ExitCode
runDnsCheck raw =
    case parseFqdn raw of
        Left err -> failWith err
        Right fqdn -> performDnsCheck fqdn
```

Decode once at the boundary. Keep the rest of the path on typed values.

## 4. Partial Functions -> Total Parsing

### Before

```haskell
parsePort :: String -> Int
parsePort = read
```

### After

```haskell
parsePort :: String -> Either String Int
parsePort raw =
    case readMaybe raw of
        Just port | port >= 1 && port <= 65535 -> Right port
        _ -> Left ("invalid port: " ++ raw)
```

Supported-path logic should not depend on `read`, `head`, `tail`, `fromJust`, or unchecked list
indexing.

## 5. Nested Conditionals -> Exhaustive Pattern Matching

### Before

```haskell
renderHealth :: Bool -> Bool -> String
renderHealth ready degraded =
    if ready
        then "healthy"
        else if degraded
            then "degraded"
            else "unhealthy"
```

### After

```haskell
data Health
    = Healthy
    | Degraded
    | Unhealthy
    deriving (Eq, Show)

renderHealth :: Health -> String
renderHealth health =
    case health of
        Healthy -> "healthy"
        Degraded -> "degraded"
        Unhealthy -> "unhealthy"
```

Closed states should become ADTs, not parallel flags.

## 6. Manual Accumulation -> Fold

### Before

```haskell
collectReadyPods :: [Pod] -> [Pod]
collectReadyPods pods = go pods []
  where
    go [] acc = reverse acc
    go (pod:rest) acc
        | podReady pod = go rest (pod : acc)
        | otherwise = go rest acc
```

### After

```haskell
collectReadyPods :: [Pod] -> [Pod]
collectReadyPods =
    foldr
        (\pod acc ->
            if podReady pod
                then pod : acc
                else acc
        )
        []
```

Use `foldr`, `foldl'`, `mapMaybe`, `traverse`, or list comprehensions when they better expose the
real data flow.

## 7. Exception-Led Ordinary Failures -> Explicit Results

### Before

```haskell
loadZoneId :: Value -> String
loadZoneId payload =
    case parseMaybe parser payload of
        Nothing -> error "missing hosted zone id"
        Just zoneId -> zoneId
```

### After

```haskell
loadZoneId :: Value -> Either String String
loadZoneId payload =
    case parseMaybe parser payload of
        Nothing -> Left "missing hosted zone id"
        Just zoneId -> Right zoneId
```

Reserve exceptions for exceptional library or runtime failures, then translate them at the
boundary if the failure is part of supported behavior.

## 8. Hidden Boundary Work -> Explicit Boundary Modules

When refactoring a mixed function, split it this way:

1. pure parser or normalizer
2. pure renderer or planner
3. boundary executor in `IO`
4. typed success or failure value returned to the caller

In this repository that usually means:

- planning in modules such as `Settings`, `ContainerImage`, `EffectDAG`, or chart helpers
- execution in `CLI`, `Native`, `Subprocess`, or `EffectInterpreter`

## 9. Review Heuristics

When deciding whether a refactor is complete, ask:

- can the decision logic be tested without mocking subprocesses
- are external strings converted to ADTs or validated newtypes early
- does the function still hide more than one responsibility
- would adding a new variant force a compiler-guided pattern-match update
- are ordinary failures represented explicitly

## Cross-References

- [Pure FP Standards](./pure_fp_standards.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Unit Testing Policy](./unit_testing_policy.md)
