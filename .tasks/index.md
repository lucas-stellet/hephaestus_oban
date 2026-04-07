# Task Plan: hephaestus_oban — Oban-based Runner Adapter

> Generated from: `docs/plans/2026-04-07-hephaestus-oban.md` + `docs/design-spec.md`
> Total tasks: 10 | Waves: 6 | Max parallelism: 3
> TDD enriched: 39 test skeletons across 8 test files

## Waves

### Wave 0 — Foundation
| Task | Title | Effort | Tests | Files |
|------|-------|--------|-------|-------|
| [task-001](task-001.md) | Project setup — dependencies, config, test support | M | — | `mix.exs`, `config/*`, `lib/hephaestus_oban/application.ex`, `test/support/*`, `test/test_helper.exs`, `priv/repo/migrations/*` |

### Wave 1 — Data Layer
| Task | Title | Effort | Tests | Files | Depends on |
|------|-------|--------|-------|-------|------------|
| [task-002](task-002.md) | Migration, step_results schema + CRUD, mix task | M | — | `lib/hephaestus_oban/migration.ex`, `lib/hephaestus_oban/schema/step_result.ex`, `lib/hephaestus_oban/step_results.ex`, `lib/mix/tasks/hephaestus_oban.gen.migration.ex` | task-001 |
| [task-003](task-003.md) | RetryConfig resolution module | S | 5 | `lib/hephaestus_oban/retry_config.ex`, `test/hephaestus_oban/retry_config_test.exs` | task-001 |

### Wave 2 — Core Orchestrator
| Task | Title | Effort | Tests | Files | Depends on |
|------|-------|--------|-------|-------|------------|
| [task-004](task-004.md) | StepResults unit tests | S | 7 | `test/hephaestus_oban/step_results_test.exs` | task-002 |
| [task-005](task-005.md) | AdvanceWorker — single Instance writer with advisory lock | L | 6 | `lib/hephaestus_oban/workers/advance_worker.ex`, `test/hephaestus_oban/workers/advance_worker_test.exs` | task-002, task-003 |

### Wave 3 — Worker Trio
| Task | Title | Effort | Tests | Files | Depends on |
|------|-------|--------|-------|-------|------------|
| [task-006](task-006.md) | ExecuteStepWorker — step executor with idempotency | M | 6 | `lib/hephaestus_oban/workers/execute_step_worker.ex`, `test/hephaestus_oban/workers/execute_step_worker_test.exs` | task-005 |
| [task-007](task-007.md) | ResumeWorker — external events and durable timers | S | 4 | `lib/hephaestus_oban/workers/resume_worker.ex`, `test/hephaestus_oban/workers/resume_worker_test.exs` | task-005 |
| [task-008](task-008.md) | FailureHandler — telemetry listener for discarded jobs | S | 5 | `lib/hephaestus_oban/failure_handler.ex`, `test/hephaestus_oban/failure_handler_test.exs` | task-005 |

### Wave 4 — Public API
| Task | Title | Effort | Tests | Files | Depends on |
|------|-------|--------|-------|-------|------------|
| [task-009](task-009.md) | Runner behaviour implementation | M | 6 | `lib/hephaestus_oban/runner.ex`, `test/hephaestus_oban/runner_test.exs` | task-006, task-007, task-008 |

### Wave 5 — Verification & Polish
| Task | Title | Effort | Tests | Files | Depends on |
|------|-------|--------|-------|-------|------------|
| [task-010](task-010.md) | Integration tests + scaffold cleanup | M | 5 | `test/hephaestus_oban/integration_test.exs`, `lib/hephaestus_oban.ex`, `test/hephaestus_oban_test.exs` | task-009 |

## Dependency Graph

```
task-001 ──→ task-002 ──→ task-004
  │            │
  │            └──→ task-005 ──→ task-006 ──→ task-009 ──→ task-010
  │                   ↑    └──→ task-007 ──↗
  └──→ task-003 ──────┘    └──→ task-008 ──↗
```

## File Conflict Check

| File | Tasks | Same wave? | Status |
|------|-------|------------|--------|
| `mix.exs` | task-001 only | N/A | OK |
| `lib/hephaestus_oban/application.ex` | task-001 only | N/A | OK |
| `config/*` | task-001 only | N/A | OK |
| `test/support/*` | task-001 only | N/A | OK |
| `test/test_helper.exs` | task-001 only | N/A | OK |
| `priv/repo/migrations/*` | task-001 only | N/A | OK |
| `lib/hephaestus_oban/migration.ex` | task-002 only | N/A | OK |
| `lib/hephaestus_oban/schema/step_result.ex` | task-002 only | N/A | OK |
| `lib/hephaestus_oban/step_results.ex` | task-002 only | N/A | OK |
| `lib/mix/tasks/*` | task-002 only | N/A | OK |
| `lib/hephaestus_oban/retry_config.ex` | task-003 only | N/A | OK |
| `lib/hephaestus_oban.ex` | task-010 only | N/A | OK |
| `test/hephaestus_oban_test.exs` | task-010 only | N/A | OK |

No file conflicts within any wave.

## Notes

- **Prerequisite:** hephaestus_ecto must be fully implemented and its migration available before starting.
- **hephaestus_core changes** (tuple config in `use Hephaestus`, optional `retry_config/0` on Step, `schedule_resume` return type) must be merged first.
- **Bottleneck:** task-005 (AdvanceWorker) is the critical path — it's the most complex worker and blocks the entire Wave 3.
- **Testing:** Uses `Oban.Testing` with `:manual` mode. Test Repo and Oban started from `test_helper.exs`, not `application.ex`.
