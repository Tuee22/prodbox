# Pure Functional Programming Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: CLAUDE.md, AGENTS.md, documents/engineering/refactoring_patterns.md

> **Purpose**: Definitive standards for pure functional programming in prodbox. All code must be pure EXCEPT the interpreter, which is the designated impurity boundary.

---

## 1. Purity Boundaries

### 1.1 The Interpreter Boundary

The key insight: **purity has boundaries**. All code must be pure EXCEPT the interpreter, which is where side effects are executed.

| Code Location | Purity | Mutation Allowed | I/O Allowed |
|---------------|--------|------------------|-------------|
| Effect DAG builders (`*_dag()`) | 100% pure | No | No |
| Smart constructors | 100% pure | No | No |
| Custom effect functions (`fn=...`) | 100% pure | No | No |
| Utility functions | 100% pure | No | No |
| `output.py` formatters | Pure | No | Return strings only |
| **`interpreter.py` `_interpret_*`** | **Impure** | **Yes** | **Yes** |
| Command entry points | Impure | No | `sys.exit()` only |

### 1.2 Why This Matters

- **Testability**: Pure code is trivially testable - no mocks needed for pure functions
- **Reasoning**: No hidden state changes makes code predictable
- **Concurrency**: No race conditions in pure code
- **Debugging**: Effects are just data - you can inspect the DAG before execution

### 1.3 Why the Interpreter is the Impurity Boundary

Effects are just data. The interpreter schedules them; thin effect implementations wrap side-effecting libraries but always return `Result[T, E]` from pure signatures. No hidden mutation or side effects live outside the interpreter.

The interpreter is where:
- Subprocess calls happen (`asyncio.create_subprocess_exec`)
- File I/O occurs (`Path.read_text()`, `Path.write_text()`)
- Network requests execute (`httpx`, `boto3`)
- Metrics counters increment (`self.total_effects += 1`)
- Error lists accumulate (`self.environment_errors.append()`)

This is acceptable because the interpreter's **sole purpose** is to execute side effects.

---

## 2. No Mutation

### 2.1 Frozen Dataclasses (REQUIRED)

All dataclasses MUST use `frozen=True`:

```python
# ✅ CORRECT
@dataclass(frozen=True)
class Command:
    name: str
    args: tuple[str, ...]

# ❌ WRONG
@dataclass
class Command:
    name: str
    args: list[str]
```

### 2.2 Immutable Collections

Use immutable collection types:

```python
# ✅ CORRECT
prerequisites: frozenset[str] = frozenset()
items: tuple[str, ...] = ()
mapping: Mapping[str, int] = {}

# ❌ WRONG
prerequisites: set[str] = set()
items: list[str] = []
mapping: dict[str, int] = {}
```

### 2.3 Creating New Values (Not Mutating)

Always create new values instead of mutating:

```python
# ✅ CORRECT
new_items = (*existing, new_item)
new_dict = {**existing, key: value}
new_set = existing_set | frozenset({new_item})

# ❌ WRONG
items.append(new_item)
dict[key] = value
set.add(new_item)
```

---

## 3. No If/Else Statements

### 3.1 Pattern Matching (REQUIRED)

Use `match/case` instead of if/else:

```python
# ✅ CORRECT
match result:
    case Success(value):
        return process(value)
    case Failure(error):
        return handle_error(error)

# ❌ WRONG
if result.is_success:
    return process(result.value)
else:
    return handle_error(result.error)
```

### 3.2 Exhaustive Matching (No Default Cases)

Handle ALL cases explicitly - no catch-all defaults that hide bugs:

```python
# ✅ CORRECT
match action:
    case Action.START:
        return start()
    case Action.STOP:
        return stop()
    case Action.RESTART:
        return restart()
    case _ as unreachable:
        _assert_never(unreachable)

# ❌ WRONG
match action:
    case Action.START:
        return start()
    case _:
        return default_handler()  # Hides unhandled cases!
```

### 3.3 Assert Never Helper

```python
from typing import Never

def _assert_never(value: object) -> Never:
    """Type-safe assertion that code path is unreachable.

    Use at the end of exhaustive match statements to ensure
    all cases are handled. If a new variant is added to the ADT,
    mypy will error until the new case is handled.
    """
    raise AssertionError(f"Unhandled case: {type(value).__name__}")
```

---

## 4. No For Loops

### 4.1 List Comprehensions (Transforms)

Use comprehensions for transformations:

```python
# ✅ CORRECT
valid_ports = tuple(p for p in ports if 1 <= p <= 65535)
names = tuple(item.name for item in items)

# ❌ WRONG
valid_ports = []
for p in ports:
    if 1 <= p <= 65535:
        valid_ports.append(p)
```

### 4.2 functools.reduce (Accumulation)

Use reduce for accumulating state:

```python
# ✅ CORRECT
from functools import reduce

def group_by(items: Sequence[T], key_fn: Callable[[T], K]) -> dict[K, tuple[T, ...]]:
    def reducer(acc: dict[K, tuple[T, ...]], item: T) -> dict[K, tuple[T, ...]]:
        key = key_fn(item)
        existing = acc.get(key, ())
        return {**acc, key: (*existing, item)}  # New dict, no mutation
    return reduce(reducer, items, {})

# ❌ WRONG
def group_by(items, key_fn):
    result = {}
    for item in items:
        key = key_fn(item)
        if key not in result:
            result[key] = []
        result[key].append(item)  # Mutation!
    return result
```

### 4.3 When For Loops ARE Allowed

For loops are permitted ONLY in interpreter `_interpret_*` methods:

```python
# OK in interpreter (impurity boundary)
async def _interpret_sequence(self, effect: Sequence) -> ExecutionSummary:
    for sub_effect in effect.effects:
        summary = await self.interpret(sub_effect)
        if summary.exit_code != 0:
            return summary
    return self._create_success_summary("Sequence completed")
```

---

## 5. ADT Exhaustiveness

### 5.1 Union Types for Closed Sets

Define commands as explicit unions:

```python
Command = (
    DNSUpdateCommand
    | RKE2StatusCommand
    | K8sHealthCommand
    | HostInfoCommand
    # ... all variants listed explicitly
)
```

### 5.2 Smart Constructors

Validate at construction time and return `Result`:

```python
def dns_update_command(*, force: bool = False) -> Result[DNSUpdateCommand, str]:
    # Validation at construction time
    return Success(DNSUpdateCommand(force=force))

def port_command(port: int) -> Result[PortCommand, str]:
    match port:
        case p if 1 <= p <= 65535:
            return Success(PortCommand(port=p))
        case _:
            return Failure(f"Invalid port: {port}. Must be 1-65535")
```

### 5.3 Result Type for Fallible Operations

```python
# ✅ CORRECT
def parse_config(content: str) -> Result[Config, str]:
    match validate_yaml(content):
        case Success(data):
            return build_config(data)
        case Failure(error):
            return Failure(f"Invalid YAML: {error}")

# ❌ WRONG
def parse_config(path: Path) -> Config:
    try:
        content = path.read_text()  # I/O in pure code!
        return yaml.safe_load(content)
    except Exception as e:
        raise ConfigError(str(e))  # Exceptions for control flow!
```

---

## 6. Type Safety

### 6.1 Zero Tolerance for Any

The following are FORBIDDEN in prodbox code:

- `Any` type annotations
- `cast()` calls
- `# type: ignore` comments

Exception: External libraries (Pulumi, boto3) may require `Any` at their boundaries. These must be isolated behind typed wrapper interfaces.

### 6.2 TypeGuard for Runtime Narrowing

```python
from typing import TypeGuard

def is_config_dict(obj: object) -> TypeGuard[dict[str, object]]:
    return isinstance(obj, dict)

# Usage
if is_config_dict(data):
    # data is now typed as dict[str, object]
    return data.get("key")
```

### 6.3 Literal Types for Restricted Values

```python
Platform: TypeAlias = Literal["linux", "darwin", "windows"]
Action: TypeAlias = Literal["start", "stop", "restart"]
LogLevel: TypeAlias = Literal["debug", "info", "warning", "error"]
```

---

## 7. Interpreter Patterns

### 7.1 Mutable Counters (OK in Interpreter)

```python
class EffectInterpreter:
    def __init__(self) -> None:
        # These mutations are OK - interpreter is impurity boundary
        self.total_effects: int = 0
        self.successful_effects: int = 0
        self.failed_effects: int = 0
        self.environment_errors: list[str] = []
```

### 7.2 Try/Except (OK in Interpreter)

```python
async def _interpret_run_subprocess(self, effect: RunSubprocess) -> ExecutionSummary:
    try:
        result = await asyncio.create_subprocess_exec(...)
        stdout, stderr = await result.communicate()
        self.successful_effects += 1
        return self._create_success_summary("Subprocess completed")
    except asyncio.TimeoutError:
        self.failed_effects += 1
        return self._create_error_summary("Timeout")
```

### 7.3 Pattern Matching for Dispatch

```python
async def _dispatch_effect(self, effect: Effect[T]) -> ExecutionSummary:
    match effect:
        case RequireLinux():
            return await self._interpret_require_linux(effect)
        case RunSubprocess():
            return await self._interpret_run_subprocess(effect)
        case WriteStdout():
            return await self._interpret_write_stdout(effect)
        # ... all effect types
        case _ as unreachable:
            return _assert_never(unreachable)
```

---

## 8. Forbidden Patterns

### 8.1 Print in Pure Code

```python
# ❌ FORBIDDEN
def validate_tools(tools: list[str]) -> bool:
    print("Checking tools...")  # Side effect in pure code!
    return all(shutil.which(t) for t in tools)

# ✅ CORRECT
def validate_tools(tools: tuple[str, ...]) -> Result[ToolReport, str]:
    # Return data, let interpreter handle output
    missing = tuple(t for t in tools if not shutil.which(t))
    match missing:
        case ():
            return Success(ToolReport(valid=True, tools=tools))
        case _:
            return Failure(f"Missing tools: {', '.join(missing)}")
```

### 8.2 sys.exit() Scattered

```python
# ❌ FORBIDDEN
def require_tools(tools: list) -> None:
    if not validate_tools(tools):
        print_error("Tools not available")
        sys.exit(1)  # Exit scattered across codebase!

# ✅ CORRECT - Only at command entry point
@cli.command()
def my_command() -> None:
    match my_command_constructor():
        case Success(cmd):
            sys.exit(execute_command(cmd))  # Single exit point
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="my_command"))
```

### 8.3 Global Mutable State

```python
# ❌ FORBIDDEN
_cached_config = None

def get_config():
    global _cached_config
    if _cached_config is None:
        _cached_config = load_config()
    return _cached_config

# ✅ CORRECT - Pass config explicitly
def process_command(config: Config, cmd: Command) -> Result[Output, str]:
    ...
```

### 8.4 I/O in Pure Functions

```python
# ❌ FORBIDDEN
def load_settings() -> Settings:
    with open("config.yaml") as f:  # I/O!
        return yaml.safe_load(f)

# ✅ CORRECT - Define as Effect, interpreter handles I/O
@dataclass(frozen=True)
class LoadSettings(Effect[Settings]):
    """Load settings from file - interpreter executes I/O."""
    config_path: Path
```

---

## 9. Quick Reference Checklist

### PR Review Checklist

**Purity Checks**:
- [ ] All dataclasses use `@dataclass(frozen=True)`
- [ ] No `list` or `set` fields (use `tuple`/`frozenset`)
- [ ] No `if`/`elif`/`else` statements outside interpreter
- [ ] No `for` loops outside interpreter (use comprehensions)
- [ ] No `try`/`except` outside interpreter (use `Result[T, E]`)
- [ ] No `case _:` default handlers (exhaustive matching)
- [ ] All smart constructors return `Result[T, E]`

**Type Safety Checks**:
- [ ] No `Any` type annotations
- [ ] No `cast()` calls
- [ ] No `# type: ignore` comments
- [ ] All functions have explicit return types
- [ ] All generics fully parameterized (`list[str]` not `list`)

**Architecture Checks**:
- [ ] No `print()` in pure code (only in interpreter)
- [ ] No `sys.exit()` scattered (only at command entry points)
- [ ] No global mutable state
- [ ] No I/O in pure functions (only in interpreter)

---

## Cross-References

- [Effectful DAG Architecture](./engineering/effectful_dag_architecture.md)
- [Prerequisite Doctrine](./engineering/prerequisite_doctrine.md)
- [CLAUDE.md](../CLAUDE.md) - Project overview
- [AGENTS.md](../AGENTS.md) - Agent guidelines
