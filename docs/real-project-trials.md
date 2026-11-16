# Real-world GoogleTest trials

Recorded on 2026-11-16, using macOS arm64, AppleClang 21.0.0, Neovim 0.12.6, CMake/CTest 4.4.5 and Ninja. These are upstream application/library checkouts, independent of the plugin's synthetic regression fixtures.

## Projects and scope

| Project | Pinned upstream revision | Tracked C++ implementation files | CMake targets | Executables |
| --- | --- | ---: | ---: | ---: |
| [Abseil](https://github.com/abseil/abseil-cpp) | `418315d7424711808e79cfbbf932557b8fe5a6bd` | 493 | 382 | 246 |
| [LevelDB](https://github.com/google/leveldb) | `29465588d3dfdc80fba5e198037582b8fdb5dd60` | 76 | 9 | 4 |

Both projects were fully built using their upstream CMake configurations. Abseil used the installed GoogleTest 1.18.0; LevelDB used its pinned GoogleTest submodule, `a35bc7693c117a048152beeb34f6aac354b9423f`. Baseline test sources and registrations were unchanged.

The checks used the real Neotest client, CMake consumer, process runner and rendered summary buffer in headless Neovim. This is not a claim of manual GUI testing or a full upstream test-suite pass. Full discovery was measured separately from selected test runs.

## Results

### Abseil

Global executable discovery found **240 binaries and 9,433 concrete cases** from 359 CTest registrations. Executable targets also include helpers and binaries with no compiled test cases. Initial discovery took 66.7 seconds; a subsequent profiled discovery took 6.4 seconds. The cause of the initial timing difference was not isolated. In the profiled run, binary framework scanning took 3.9 seconds and subprocess enumeration 2.3 seconds.

| Selected source | Displayed rows | Passed | Skipped | Parameter rows | Native cases executed by its registration | File run |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `absl/strings/str_split_test.cc` | 34 | 34 | 0 | 0 | 34 | 0.74 s |
| `absl/base/log_severity_test.cc` | 66 | 66 | 0 | 61 | 66 | 0.70 s |
| `absl/numeric/int128_test.cc` | 88 | 88 | 0 | 54 | 92 | 0.91 s |
| `absl/container/flat_hash_map_test.cc` | 18 | 15 | 3 | 0 | 310 | 1.18 s |

The three skipped hash-map definitions are not compiled into this C++17 configuration. The integer executable also contains four tests from `int128_stream_test.cc`, accounting for 92 native cases versus 88 rows in the selected source file. Hash-map executables also run tests defined in shared helper headers.

Selecting individual value and typed rows preserved their exact GoogleTest names and passing results in the summary. Their whole-executable CTest registrations still ran 66 and 92 native cases, respectively; source selection does not rewrite upstream registration boundaries. The largest sampled event-loop gap during these file/summary trials was 470 ms; these measurements are not an interactive responsiveness guarantee.

A deliberate compile error was temporarily appended to `int128_test.cc` after successful runs. The adapter opened quickfix, launched **zero stale tests**, reset all 88 rows and the sibling stream-test file's cached results, and retained the unrelated string-splitting results. Restoring the source rebuilt and passed. The checkout was returned to its original contents.

### LevelDB

Executable discovery found **2 GoogleTest binaries and 220 concrete cases**, taking 0.50 seconds. Other executable targets include a utility and a C test program.

A run of `util/status_test.cc` displayed its one passing test but executed the complete `leveldb_tests` registration: **213 cases**, taking 99.6 seconds. That registration passed 211 cases and intentionally skipped two compression cases because Snappy and Zstd were not available in this configuration.

| Selected source | Displayed rows | Passed | Skipped | Parameter rows | Native cases executed | File run |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `table/table_test.cc` | 13 | 11 | 2 | 2 | 213 | 97.7 s |
| `util/env_posix_test.cc` | 7 | 7 | 0 | 0 | 7 | 0.08 s |

Selecting `CompressionTests/CompressionTableTest.ApproximateOffsetOfCompressed/0` preserved the correct **skipped** outcome, matching the native `GTEST_SKIP()` for an unavailable compression codec. Its registration again executed all 213 cases, taking 98.1 seconds. The summary displayed the concrete parameter name and distinct per-case statuses correctly.

## Correctness bug found and fixed

CTest truncates successful test output to 1 KiB and failed test output to 300 KiB by default. This breaks per-case result extraction inside whole-executable registrations.

Before the fix, Abseil's string-splitting executable ran all 34 tests successfully, but the adapter reported only 11 passed and 23 skipped: the remaining result lines had been removed from the JUnit `system-out`. A regression fixture also reproduced a passing test after a verbose failure being incorrectly reported as failed.

The adapter now requests complete output using `--test-output-size-passed 0` and `--test-output-size-failed 0`. These [CTest options](https://cmake.org/cmake/help/latest/manual/ctest.1.html#cmdoption-ctest-test-output-size-passed) predate the plugin's minimum CMake version. Both cases are covered by real CTest regression tests, including parameterized passing tests and output exceeding 300 KiB. After the fix, the Abseil file correctly reports 34 passed and zero skipped.

## Remaining limitations exposed by the trial

- **Header-only interface helpers:** `absl/container/internal/unordered_map_lookup_test.h` contains five `TYPED_TEST_P` definitions, instantiated by hash-map executables. GoogleTest lists the compiled instances, but this configuration's File API codemodel omits the header-only interface target/source ownership. The adapter finds no owning executable and cannot expand those five source definitions into concrete rows. This needs an ownership solution beyond the current File API source mapping; it was not hidden by changing upstream sources or registrations.
- **Whole-executable registrations:** selecting one source test or parameter can still run hundreds of cases. LevelDB makes the cost particularly visible. This follows upstream `add_test(NAME ... COMMAND executable)` registrations. Per-case registration through `gtest_discover_tests()` offers a different execution boundary, but was not substituted in these upstream checkouts.
- **Conditional definitions:** Abseil's `cordz_test.cc` compiles to a binary with no test cases on this platform, while static source discovery can still see definitions. Source parsing does not preprocess conditional compilation.
- **Scale and cold discovery:** full executable discovery is not instantaneous, and individual file discovery/build preparation can briefly block the event loop while processing metadata. The first large-project measurement is recorded above rather than presented as a warm-cache benchmark.

## Full Abseil source-tree scan

The real Neotest client scanned the project and expanded its actual summary buffer:

| Measurement | Before metadata caching | After metadata caching |
| --- | ---: | ---: |
| Source files with discovered tests | 255 | 255 |
| Source test rows | 7,883 | 7,883 |
| Concrete parameter rows | 3,961 | 3,961 |
| Rendered summary lines | 8,703 | 8,703 |
| Source discovery time | 67.79 s | 13.15 s |
| Largest sampled event-loop gap | 1,991 ms | 305 ms |

A 20 ms scheduled timer sampled the event loop during discovery. These are single local measurements, not a cross-platform performance claim. Source-row totals need not equal runtime case totals: shared sources can be compiled into multiple binaries, conditional definitions can remain visible, and the header-ownership gap above still applies.

Repeatedly reading and processing unchanged File API JSON for each source was avoidable. The adapter now caches target metadata by build directory, configuration and the reply index's path/size/mtime. A regression moves a source into another executable's object library, reconfigures CMake, and verifies that ownership changes and then recovers after restoration. This optimization does not add include scanning or change header-ownership rules.

## Reproduce the builds

Use separate checkouts and an environment with CMake, Ninja, a C++17 compiler and GoogleTest available. Fetch the revisions above if the default branches have advanced.

### Abseil

```sh
git clone --depth 1 https://github.com/abseil/abseil-cpp.git
cd abseil-cpp
git fetch --depth 1 origin 418315d7424711808e79cfbbf932557b8fe5a6bd
git checkout --detach FETCH_HEAD
mkdir -p build/.cmake/api/v1/query
touch build/.cmake/api/v1/query/codemodel-v2
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DABSL_BUILD_TESTING=ON -DABSL_USE_EXTERNAL_GOOGLETEST=ON \
  -DABSL_FIND_GOOGLETEST=ON -DABSL_ENABLE_INSTALL=OFF
cmake --build build --parallel 6
nvim absl/base/log_severity_test.cc
```

### LevelDB

```sh
git clone --depth 1 https://github.com/google/leveldb.git
cd leveldb
git fetch --depth 1 origin 29465588d3dfdc80fba5e198037582b8fdb5dd60
git checkout --detach FETCH_HEAD
git submodule update --init --depth 1 third_party/googletest
mkdir -p build/.cmake/api/v1/query
touch build/.cmake/api/v1/query/codemodel-v2
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DLEVELDB_BUILD_TESTS=ON \
  -DLEVELDB_BUILD_BENCHMARKS=OFF -DLEVELDB_INSTALL=OFF
cmake --build build --parallel 4
nvim table/table_test.cc
```

Configure Neotest using the README's standalone setup, with `build_dir = "build"` and the CMake consumer. Save the source, run `require("neotest").cmake.run(vim.fn.expand("%:p"))`, and open `require("neotest").summary.toggle()`. Select a concrete parameter row in the summary to exercise individual selection. The plugin installs no project-specific mappings and requires no changes to either upstream source tree.
