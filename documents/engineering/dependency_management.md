# Dependency Management Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: CLAUDE.md, README.md

> **Purpose**: Define standards for Python dependency management in prodbox using Poetry.

---

## 1. Lock File Policy

### poetry.lock is NOT Version Controlled

The `poetry.lock` file is excluded from version control via `.gitignore`:

```gitignore
# File: .gitignore
poetry.lock
```

### Rationale

1. **Local reproducibility**: Each developer generates `poetry.lock` locally via `poetry install`
2. **Environment flexibility**: Different platforms (Linux/macOS) may resolve dependencies differently
3. **Reduced merge conflicts**: Lock files cause frequent, noisy merge conflicts
4. **Explicit bounds suffice**: With proper version constraints in `pyproject.toml`, builds remain reproducible within acceptable bounds

### Developer Workflow

```bash
# Fresh clone - generates poetry.lock locally
git clone <repo>
cd prodbox
poetry install

# After pulling changes to pyproject.toml
poetry lock --no-update  # Regenerate lock without upgrading
poetry install
```

---

## 2. Version Constraint Standards

### Required: Explicit Upper Bounds

Every dependency in `pyproject.toml` MUST have an explicit upper bound using one of two forms:

#### Option 1: Caret Bounds (Preferred)

```toml
# Allows compatible updates within major version
click = "^8.1.0"      # >=8.1.0, <9.0.0
pydantic = "^2.0.0"   # >=2.0.0, <3.0.0
```

#### Option 2: Explicit Upper Bound

```toml
# For packages where caret semantics don't fit
python = "3.12.*"           # Only Python 3.12.x
some-package = ">=1.0,<2.0" # Explicit range
```

### Why Caret Bounds

The caret (`^`) operator follows SemVer:
- `^X.Y.Z` allows updates that don't modify the left-most non-zero digit
- `^8.1.0` means `>=8.1.0, <9.0.0`
- `^0.27.0` means `>=0.27.0, <0.28.0` (for 0.x versions)

This provides:
- **Automatic patch updates**: Security fixes applied automatically
- **Compatible minor updates**: New features without breaking changes
- **Protected major versions**: Breaking changes require explicit upgrade

### Forbidden Patterns

```toml
# BAD: Unbounded - allows any version
click = "*"

# BAD: No upper bound - could pull breaking changes
click = ">=8.0"

# BAD: Pinned exactly - misses security patches
click = "8.1.7"
```

---

## 3. Current Dependencies

### Runtime Dependencies

```toml
# File: pyproject.toml
[tool.poetry.dependencies]
python = "3.12.*"
click = "^8.1.0"
pydantic = "^2.0.0"
pydantic-settings = "^2.0.0"
pulumi = "^3.0.0"
pulumi-kubernetes = "^4.0.0"
pulumi-aws = "^6.0.0"
boto3 = "^1.28.0"
httpx = "^0.27.0"
rich = "^13.0.0"
```

### Development Dependencies

```toml
# File: pyproject.toml
[tool.poetry.group.dev.dependencies]
pytest = "^8.0.0"
pytest-asyncio = "^0.23.0"
pytest-cov = "^4.0.0"
pytest-mock = "^3.12"
pytest-timeout = "^2.3"
pytest-subprocess = "^1.5"
mypy = "^1.7.0"
ruff = "^0.2.0"
```

---

## 4. Adding New Dependencies

### Checklist

1. **Check existing dependencies**: Avoid duplicates or conflicts
2. **Use caret bounds**: `poetry add "package^X.Y.0"`
3. **Verify type stubs**: Add to `typings/` if needed (see [Type Safety](../CLAUDE.md#type-safety))
4. **Run tests**: `poetry run pytest`
5. **Run type checker**: `poetry run mypy src/`

### Example

```bash
# Add runtime dependency
poetry add "aiofiles^23.0.0"

# Add dev dependency
poetry add --group dev "hypothesis^6.0.0"
```

---

## 5. Upgrading Dependencies

### Safe Upgrade Process

```bash
# 1. See what's outdated
poetry show --outdated

# 2. Update within bounds (safe)
poetry update

# 3. Run full test suite
poetry run pytest
poetry run mypy src/

# 4. For major version upgrades, update pyproject.toml explicitly
# Then regenerate lock
poetry lock
poetry install
```

### Major Version Upgrades

Major version upgrades require:
1. Review changelog for breaking changes
2. Update `pyproject.toml` with new caret bound
3. Update any affected code
4. Update type stubs if needed
5. Full test suite pass

---

## Cross-References

- [CLAUDE.md](../../CLAUDE.md) - Project overview and type safety requirements
- [Pure FP Standards](./pure_fp_standards.md) - Code patterns that affect dependency choices
- [pyproject.toml](../../pyproject.toml) - Canonical dependency definitions
