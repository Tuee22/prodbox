# Refactoring to Pure FP

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: CLAUDE.md

> **Purpose**: Before/after patterns for migrating imperative code to pure functional programming.

---

## 1. Exception → Result

### Before (Violation)

```python
async def update_dns(settings: Settings) -> None:
    try:
        public_ip = await get_public_ip()
        print_info(f"Current public IP: {public_ip}")
    except Exception as e:
        print_error(f"Failed to get public IP: {e}")
        raise SystemExit(1)
```

### After (Pure)

```python
def dns_update_dag(settings: Settings) -> EffectDAG:
    """Pure DAG builder - no I/O, no exceptions."""
    return EffectDAG.from_roots(
        EffectNode(
            effect=Sequence(
                effect_id="dns_update_workflow",
                description="Update DNS record",
                effects=[
                    FetchPublicIP(
                        effect_id="fetch_ip",
                        description="Get current public IP"
                    ),
                    QueryRoute53Record(
                        effect_id="query_dns",
                        description="Query current DNS",
                        zone_id=settings.route53_zone_id,
                        fqdn=settings.fqdn
                    ),
                    # ... more effects
                ]
            ),
            prerequisites=frozenset(["aws_credentials_valid"])
        ),
        registry=PREREQUISITE_REGISTRY
    )
```

---

## 2. If/Else → Match

### Before (Violation)

```python
def get_health_status(status: str) -> str:
    if "Ready" in status:
        return "healthy"
    elif "NotReady" in status:
        return "unhealthy"
    else:
        return "unknown"
```

### After (Pure)

```python
def get_health_status(status: str) -> str:
    match status:
        case s if "Ready" in s:
            return "healthy"
        case s if "NotReady" in s:
            return "unhealthy"
        case _:
            return "unknown"
```

### ADT Version (Even Better)

```python
@dataclass(frozen=True)
class Healthy:
    """Node is ready."""

@dataclass(frozen=True)
class Unhealthy:
    reason: str

@dataclass(frozen=True)
class Unknown:
    raw_status: str

NodeHealth = Healthy | Unhealthy | Unknown

def parse_health(status: str) -> NodeHealth:
    match status:
        case s if "Ready" in s:
            return Healthy()
        case s if "NotReady" in s:
            return Unhealthy(reason="NotReady condition")
        case _:
            return Unknown(raw_status=status)
```

---

## 3. For Loop → Comprehension

### Before (Violation)

```python
def find_conflicts(ports: list[int]) -> list[int]:
    conflicts = []
    for port in ports:
        if is_port_in_use(port):
            conflicts.append(port)
    return conflicts
```

### After (Pure)

```python
def find_conflicts(ports: tuple[int, ...]) -> tuple[int, ...]:
    return tuple(port for port in ports if is_port_in_use(port))
```

### Multiple Transformations

```python
# Before
def process_items(items: list[Item]) -> list[str]:
    results = []
    for item in items:
        if item.is_valid:
            processed = transform(item)
            results.append(processed.name)
    return results

# After
def process_items(items: tuple[Item, ...]) -> tuple[str, ...]:
    return tuple(
        transform(item).name
        for item in items
        if item.is_valid
    )
```

---

## 4. Mutable Accumulator → Reduce

### Before (Violation)

```python
def group_by_status(pods: list[Pod]) -> dict[str, list[Pod]]:
    result = {}
    for pod in pods:
        status = pod.status
        if status not in result:
            result[status] = []
        result[status].append(pod)
    return result
```

### After (Pure)

```python
from functools import reduce

def group_by_status(pods: tuple[Pod, ...]) -> dict[str, tuple[Pod, ...]]:
    def reducer(
        acc: dict[str, tuple[Pod, ...]],
        pod: Pod
    ) -> dict[str, tuple[Pod, ...]]:
        status = pod.status
        existing = acc.get(status, ())
        return {**acc, status: (*existing, pod)}

    return reduce(reducer, pods, {})
```

---

## 5. Default Case → Exhaustive Match

### Before (Violation)

```python
def handle_action(action: str) -> int:
    match action:
        case "start":
            return start_service()
        case "stop":
            return stop_service()
        case _:
            return 1  # Silent failure for unknown actions!
```

### After (Pure)

```python
from typing import Literal, Never

Action = Literal["start", "stop", "restart", "status"]

def _assert_never(value: object) -> Never:
    raise AssertionError(f"Unhandled case: {value}")

def handle_action(action: Action) -> int:
    match action:
        case "start":
            return start_service()
        case "stop":
            return stop_service()
        case "restart":
            return restart_service()
        case "status":
            return get_status()
        case _ as unreachable:
            _assert_never(unreachable)
```

---

## 6. Mutable Dataclass → Frozen

### Before (Violation)

```python
@dataclass
class Config:
    name: str
    items: list[str]
    settings: dict[str, int]

# Allows mutation
config = Config(name="test", items=[], settings={})
config.items.append("item")  # Mutation!
config.settings["key"] = 42  # Mutation!
```

### After (Pure)

```python
@dataclass(frozen=True)
class Config:
    name: str
    items: tuple[str, ...]
    settings: Mapping[str, int]

# Immutable - create new instances
config = Config(name="test", items=(), settings={})
new_config = Config(
    name=config.name,
    items=(*config.items, "item"),
    settings={**config.settings, "key": 42}
)
```

---

## 7. List/Set → Tuple/Frozenset

### Before (Violation)

```python
def get_prerequisites() -> set[str]:
    return {"tool_kubectl", "kubeconfig_exists"}

def get_required_tools() -> list[str]:
    return ["kubectl", "helm", "pulumi"]
```

### After (Pure)

```python
def get_prerequisites() -> frozenset[str]:
    return frozenset({"tool_kubectl", "kubeconfig_exists"})

def get_required_tools() -> tuple[str, ...]:
    return ("kubectl", "helm", "pulumi")
```

---

## 8. Print Statements → Effect Data

### Before (Violation)

```python
def check_cluster_health() -> bool:
    print("Checking cluster health...")  # Side effect!
    status = get_cluster_status()
    if status.healthy:
        print("✓ Cluster is healthy")  # Side effect!
        return True
    else:
        print(f"✗ Cluster unhealthy: {status.error}")  # Side effect!
        return False
```

### After (Pure)

```python
@dataclass(frozen=True)
class HealthCheckResult:
    healthy: bool
    message: str

def check_cluster_health_effect() -> Sequence:
    """Build pure effect sequence - interpreter handles output."""
    return Sequence(
        effect_id="cluster_health_check",
        description="Check cluster health",
        effects=[
            PrintInfo(
                effect_id="health_start",
                description="Print check starting",
                message="Checking cluster health..."
            ),
            CaptureKubectlOutput(
                effect_id="get_nodes",
                description="Get node status",
                args=["get", "nodes", "-o", "json"]
            ),
            # Custom effect to process and display result
            Custom(
                effect_id="display_result",
                description="Display health result",
                fn=format_health_result  # Pure function
            )
        ]
    )
```

---

## 9. Global State → Explicit Parameters

### Before (Violation)

```python
_settings: Settings | None = None

def get_settings() -> Settings:
    global _settings
    if _settings is None:
        _settings = load_settings_from_env()
    return _settings

def update_dns() -> None:
    settings = get_settings()  # Hidden dependency!
    # ...
```

### After (Pure)

```python
def dns_update_dag(settings: Settings) -> EffectDAG:
    """Settings passed explicitly - no hidden state."""
    return EffectDAG.from_roots(
        EffectNode(
            effect=UpdateRoute53Record(
                effect_id="update_dns",
                description="Update DNS record",
                zone_id=settings.route53_zone_id,
                fqdn=settings.fqdn,
                ip="",  # Will be filled by prerequisite
            ),
            prerequisites=frozenset(["fetch_public_ip", "aws_credentials_valid"])
        ),
        registry=PREREQUISITE_REGISTRY
    )
```

---

## 10. try/except → Result Pattern

### Before (Violation)

```python
def parse_yaml_config(path: Path) -> Config:
    try:
        content = path.read_text()
        data = yaml.safe_load(content)
        return Config(**data)
    except FileNotFoundError:
        raise ConfigError(f"Config file not found: {path}")
    except yaml.YAMLError as e:
        raise ConfigError(f"Invalid YAML: {e}")
    except TypeError as e:
        raise ConfigError(f"Invalid config structure: {e}")
```

### After (Pure)

```python
def parse_yaml_config(content: str) -> Result[Config, str]:
    """Pure parser - takes content, returns Result. No I/O."""
    try:
        data = yaml.safe_load(content)
    except yaml.YAMLError as e:
        return Failure(f"Invalid YAML: {e}")

    match validate_config_data(data):
        case Success(config_data):
            return Success(Config(**config_data))
        case Failure(error):
            return Failure(f"Invalid config structure: {error}")

# I/O happens in Effect
@dataclass(frozen=True)
class LoadConfig(Effect[Config]):
    """Effect to load config - interpreter handles I/O."""
    path: Path
```

---

## Summary Table

| Pattern | Imperative (Wrong) | Functional (Correct) |
|---------|-------------------|---------------------|
| Error handling | `try/except` + `raise` | `Result[T, E]` + `match` |
| Branching | `if/elif/else` | `match/case` |
| Iteration | `for` loop | Comprehension |
| Accumulation | Mutable loop variable | `reduce()` |
| Default case | `case _: ...` | Exhaustive + `_assert_never` |
| Data class | `@dataclass` | `@dataclass(frozen=True)` |
| Lists | `list[T]` | `tuple[T, ...]` |
| Sets | `set[T]` | `frozenset[T]` |
| Output | `print()` | `WriteStdout` effect |
| Global state | Module-level variables | Explicit parameters |

---

## Cross-References

- [Pure FP Standards (SSoT)](./pure_fp_standards.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
