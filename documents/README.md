# Prodbox Documentation

**Status**: Reference only
**Referenced by**: CLAUDE.md

> **Purpose**: Index of prodbox documentation.

---

## Documentation Structure

```
documents/
├── README.md                      # This file
├── documentation_standards.md     # SSoT for documentation rules
├── pure_fp_standards.md           # Pure FP coding standards
├── refactoring_patterns.md        # Migration patterns for pure FP
└── engineering/
    ├── README.md                  # Engineering docs index
    ├── dependency_management.md   # Poetry dependency standards
    ├── distributed_gateway_architecture.md  # Multi-node gateway design
    ├── effectful_dag_architecture.md  # DAG system design
    ├── tla/
    │   ├── README.md              # TLA+ model index
    │   ├── gateway_orders_rule.tla      # Orders/rule safety model
    │   └── gateway_orders_rule.cfg      # TLC model configuration
    └── prerequisite_doctrine.md   # Fail-fast philosophy
```

---

## Key Documents

| Document | Purpose |
|----------|---------|
| [documentation_standards.md](./documentation_standards.md) | Rules for writing documentation |
| [pure_fp_standards.md](./pure_fp_standards.md) | Pure FP coding standards |
| [refactoring_patterns.md](./refactoring_patterns.md) | Migration patterns for pure FP |
| [engineering/dependency_management.md](./engineering/dependency_management.md) | Poetry dependency standards |
| [engineering/distributed_gateway_architecture.md](./engineering/distributed_gateway_architecture.md) | Multi-node gateway and leader failover design |
| [engineering/effectful_dag_architecture.md](./engineering/effectful_dag_architecture.md) | CLI DAG architecture |
| [engineering/prerequisite_doctrine.md](./engineering/prerequisite_doctrine.md) | Prerequisite design philosophy |
| [engineering/tla/README.md](./engineering/tla/README.md) | TLA+ model index |
| [engineering/unit_testing_policy.md](./engineering/unit_testing_policy.md) | Interpreter-Only Mocking Doctrine |

---

## Related Files

- **CLAUDE.md**: AI assistant guidelines (repository root)
- **AGENTS.md**: Agent guidelines (repository root)
- **README.md**: Project overview (repository root)
