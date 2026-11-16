# Implementation guide

The public adapter is a shared instance configured with `require('neotest-cmake')({...})`. The refactor after `v0.0.1` preserves that API and the existing consumer, execution modes and options.

## Responsibilities

| Module | Responsibility |
| --- | --- |
| `init.lua` | Neotest adapter methods and construction of CTest, direct and debugger run specifications. |
| `project.lua` | Configuration, root/build resolution, preparation, runtime enumeration and caches scoped to build contexts. |
| `discovery.lua` | File API metadata, source ownership and binary framework detection. |
| `source.lua` | C++ Tree-sitter definitions, concrete parameter rows and source/name matching. |
| `results.lua` | Result collection and the shared worst-status reducer; CTest policy remains distinct from direct execution. |
| `consumer.lua` | Build/refresh/run orchestration, source-mark aggregation and Neotest private-state integration. |
| `diagnostics.lua` | Quickfix reporting and completed failure specifications for ordinary Neotest actions. |
| `parsers.lua` | GoogleTest listing/output and CTest JUnit decoding. |
| `runner.lua` | Standalone coordination of mixed CTest/direct specifications; retained for Neotest process/output isolation. |

## Preparation and execution

1. Resolve one selection: source files, owning targets, executable artifacts and all affected source files.
2. Build that selection. A lock shared by the binary directory serializes builds across configurations.
3. Refresh source positions to include the compiled parameter names.
4. Pass a one-use preparation record to `build_spec()`. Reuse requires the same context, options, source selection, File API model and tracked input/artifact stamps.
5. If reuse is invalid, perform fresh preparation. Standard Neotest actions without a record also prepare normally.

A normal consumer action builds once. Repeating the last run does not reuse its consumed record. Tracked source/configuration stamps are captured **before** the build and artifact stamps afterwards, so an edit around the handoff is not silently accepted as part of the successful build. Tests cover changes on both sides of the public preparation return, as well as CMake ownership changes.

Build failures leave affected sources unbuilt, open quickfix, prevent execution and invalidate stale results through the consumer. No artificial `unknown` Neotest result status is introduced: neutral display follows from removing stale results.

## Cache ownership

- File API models remain in `discovery.lua`, invalidated by the reply index signature.
- Project build choices are remembered by source root for explicit external build integration.
- Build-directory state holds the shared build lock and per-configuration caches.
- Runtime listing keys include executable size/mtime, argv, cwd and environment; successful builds do not blanket-clear this cache.
- Per-source parameter names retain their binary stamp and File API model. Dirty/unbuilt sources can reuse known names without launching the previous executable.

The preparation record belongs to one invocation, not a reusable global "already built" flag. Neotest private-state access is confined to the consumer. Header-only interface ownership limitations documented in the real-project trials remain unchanged.
