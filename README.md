# neotest-cmake

A [neotest](https://github.com/nvim-neotest/neotest) adapter for CMake projects using GoogleTest. Adapted from [cmake-tests.nvim](https://github.com/mjrogozinski/cmake-tests.nvim), retaining its CTest execution model and GoogleTest/JUnit parsers.

- Discover `TEST`, `TEST_F`, `TEST_P`, `TYPED_TEST`, and `TYPED_TEST_P` definitions with the C++ Tree-sitter parser.
- Display every value and type parameter instance using its exact GoogleTest name, grouped under its Tree-sitter source definition.
- Build the executable targets owning the selected sources before running tests; a failed build stops execution.
- Run selected CTest registrations, preserving fixtures, working directories, environment settings, skip rules, expected failures, and timeouts.
- Discover unregistered GoogleTest executable targets with the CMake File API, using the same mechanism as cmake-tests.nvim.
- Report pass, failure, skip, and individual case output through neotest.

Requires Neovim 0.10+, CMake/CTest 3.21+, neotest, nvim-nio, plenary.nvim, and an installed **C++ Tree-sitter parser**. GoogleTest belongs to the project being tested.

## Install

Example lazy.nvim spec; merge the adapter into your existing neotest configuration if you already have one:

```lua
return {
  'nvim-neotest/neotest',
  dependencies = {
    'nvim-lua/plenary.nvim',
    'nvim-neotest/nvim-nio',
    'nvim-treesitter/nvim-treesitter',
    'mjrogozinski/neotest-cmake',
  },
  opts = function(_, opts)
    opts.adapters = opts.adapters or {}
    table.insert(opts.adapters, require('neotest-cmake')({
      build_dir = 'build', -- absolute path or function(root) -> path
      config = '',         -- e.g. 'Debug' for multi-config generators
      jobs = 4,
    }))
  end,
}
```

Install the `cpp` parser through your Tree-sitter configuration. Configure and build your project before running tests:

```sh
mkdir -p build/.cmake/api/v1/query
touch build/.cmake/api/v1/query/codemodel-v2
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build --parallel
```

Then use your normal neotest commands:

```lua
require('neotest').run.run()                    -- nearest source test
require('neotest').run.run(vim.fn.expand('%'))   -- current file
require('neotest').summary.toggle()
require('neotest').output.open({ enter = true })
```

CTest registration is optional. The File API query above lets the adapter locate built executable targets, detect GoogleTest binaries, and enumerate their concrete cases. It runs unregistered targets directly with an exact `--gtest_filter`. Create the query before configuring; an existing build needs one reconfigure to produce the reply.

For registered executables, `gtest_discover_tests()` gives precise CTest selection:

```cmake
enable_testing()
find_package(GTest CONFIG REQUIRED)
add_executable(unit_tests tests.cpp)
target_link_libraries(unit_tests PRIVATE GTest::gtest_main)
include(GoogleTest)
gtest_discover_tests(unit_tests)
```

Configure the build once using your normal toolchain/preset. The adapter builds relevant executable targets before every run, including their linked-library dependencies. It uses the configured build directory and never chooses a preset or fetches dependencies. If an existing build lacks File API metadata, the adapter requests codemodel-v2 and reconfigures that build using its cache before selecting targets.

Build and configure failures open quickfix with clickable compiler diagnostics and stop test execution without an error popup. The CMake consumer resets tests in the affected executable to neutral not-run marks, including parameter groups and tests in sibling source files; unrelated executables retain their results. Save-triggered discovery reuses known parameter names while sources are unbuilt, without launching the old binary. Relative diagnostic paths resolve from the build directory. Errors without a source location link to the captured build log. The source window keeps focus so you can fix and rerun; a successful rebuild clears this adapter's current quickfix list. Trouble users can also view that list with `:Trouble qflist open` (commonly `<leader>xQ`).

## Configuration

```lua
require('neotest-cmake')({
  build_dir = 'build',
  config = '',
  jobs = 1,
  ctest = 'ctest',
  cmake = 'cmake',
  build = true,            -- false only if an external runner guarantees a fresh build
  build_timeout = 120000,   -- milliseconds per configure/build process
  dap = { type = 'codelldb' }, -- requires the matching nvim-dap adapter
  discovery_timeout = 10000, -- milliseconds per discovery process
  ctest_args = {},          -- additional CTest execution options
  frameworks = {},          -- executable absolute path/basename -> 'gtest' or 'ctest'
  -- root = '/path/to/project', -- or function(path) -> root
})
```

The root is found using CMakePresets.json or .git, falling back to CMakeLists.txt. Set `root` explicitly for nested projects. `build_dir` may also be a function of the root. Supply the preset's binary directory explicitly when using presets. Configuration is shared by this adapter instance.

Unknown executables are never launched to guess their framework. GoogleTest detection scans static flag strings and shared-library dependency names (up to 64 MiB), including Nix-linked dylibs; use `frameworks` for unusual binaries. Enumeration reuses the registration's command, existing GoogleTest filter, working directory, and `ENVIRONMENT` properties. Registered executables run through CTest; unregistered File API targets run directly from the build directory. Executables already referenced by CTest commands are excluded from direct discovery to preserve their registration semantics.

## Build integration

To refresh the parameter list after building (including newly added parameters), add the optional consumer alongside your other consumers:

```lua
require('neotest').setup({
  consumers = { cmake = require('neotest-cmake.consumer') },
  adapters = { require('neotest-cmake')({ build_dir = 'build' }) },
})
-- Use these in run keymaps, after saving modified buffers:
require('neotest').cmake.run()                  -- build, refresh, run nearest definition
require('neotest').cmake.run(vim.fn.expand('%')) -- build, refresh, run file
```

The consumer forwards other adapters to normal Neotest execution. It builds before refreshing source positions, so added/removed parameters are reflected in the run and summary. Standard Neotest run and summary actions also build through `build_spec`; the consumer additionally refreshes the tree before selection. `cmake.refresh(path)` refreshes positions after an external build. This consumer uses Neotest's client position-update method and is covered by real client/runner/summary integration tests.


An external build helper can pass the actual CMake binary directory and configuration to the adapter after a successful build. Call this inside an nvim-nio task:

```lua
require('nio').run(function()
  local result = require('neotest-cmake').discover({
    root = '/path/to/source',
    build_dir = '/path/to/preset/binary/directory',
    config = 'Debug',
  })
  require('nio').scheduler()
  vim.notify(('Discovered %d GoogleTest binaries, %d cases in %s')
    :format(result.binaries, result.cases, result.build_dir))
end)
```

This validates the File API executable metadata, enumerates registered and unregistered GoogleTests, and remembers that project's build directory/configuration for subsequent runs in the current Neovim session. The File API query must be present before configuring. Keep `build_dir` configured appropriately for later sessions; it may be a function that resolves your project's compilation database symlink or preset output directory.

## Selection and limitations

CTest registrations are the execution boundary. For `gtest_discover_tests()`, each concrete parameter row selects its own registration. A parameterized/typed source definition is a namespace containing separate test rows such as `Numbers/Values.Positive/1`, `Typed/1.Size`, or `Instances/TypeParameters/1.Size`. Names come from `--gtest_list_tests`, not CTest display names (which may substitute parameter values or type names). Running nearest from the definition selects the group and runs all its instances; selecting a summary child runs only that instance. With `add_test(NAME ... COMMAND executable)`, selecting any case runs the entire registration. Individual case output determines results inside a failed group. CTest may also run fixture setup and cleanup registrations.

Unregistered targets support exact case/file selection, including all matching parameterized and typed instantiations. Mixed selections run a CTest batch and each unregistered binary sequentially within one neotest process, keeping captured output and results separate for each command. A clean headless Neovim process runs these commands without loading your configuration. Direct targets have no CTest fixture or environment properties; register them with CTest if they require those launch settings. `extra_args` are passed to CTest for registered runs and to the executable for direct runs.

DAP runs build first and launch the selected GoogleTest binary directly, with exact case filters and the registration's working directory/environment. They require nvim-dap and a configured adapter (default `codelldb`). A debug selection must use one binary and launch environment; CTest fixture registrations are rejected because the debugger cannot reproduce CTest's fixture lifecycle. Normal runs continue to use CTest policies, timeouts and expected-failure semantics.

Qt Test, custom test macros, and generated definitions without source positions are outside this adapter's current scope. Source discovery does not preprocess C++, so conditional compilation can leave unmatched definitions, which are reported as skipped in a selected file.

Custom launchers and `ENVIRONMENT_MODIFICATION` requirements can prevent enumeration: these CTest properties are preserved during execution but are not reproduced during direct `--gtest_list_tests` discovery. Such registrations may not match source tests. Source ownership from the File API limits selection to the owning executable targets, including tests compiled through linked libraries. A source compiled into multiple executables selects all its owners. Without File API metadata and with `build = false`, duplicate suite/case names may select all matching registrations. GoogleTest output must use its normal text format for detailed results inside whole-executable registrations. Missing JUnit results are failures, never inferred successes.

## Development

With GoogleTest installed and discoverable by CMake:

```sh
make test
```

The tests use real neotest trees, real CTest processes, and compiled GoogleTest fixtures. They verify source discovery, false positives in comments/strings, parameterized and typed cases, passes/failures/skips/disabled tests, exact selection, regex escaping in registration names, grouped results, environment preservation, fixture cleanup, expected failures, skip rules, timeouts, missing reports, unregistered binary discovery, exact direct selection, multiple executables, linked-library source ownership, mixed registered/direct runs, independent parameter statuses, DAP launch specifications and filters, fresh builds, unrelated broken targets, build failures blocking stale execution, and refreshed enumeration after parameter changes. A second suite uses the real Neotest client, runner and rendered summary to check every concrete row, file runs, nearest groups, individual parameter runs, and newly added parameters built and discovered during a run.

The test runner finds neotest, nvim-nio, and plenary.nvim under `~/.local/share/nvim/lazy` by default. Override `NEOTEST_DEPS` with a directory containing those checkouts. `CPP_PARSER_DIR` can point to a runtime directory containing `parser/cpp.so`. Set `CMAKE_PREFIX_PATH` if GoogleTest is installed outside your CMake search path.

MIT licensed. The original cmake-tests.nvim copyright is retained in LICENSE.

The real-client suite can also exercise the warmup C++ project and optionally its actual Neovim keymap callbacks (the script stays in this plugin repository):

```sh
WARMUP_ROOT=/path/to/warmup NEOTEST_BUILD_DIR=build/clang \
  nvim --headless -i NONE -u tests/init.lua '+luafile tests/neotest.lua'
# Optional: NEOTEST_KEYMAP_SPEC=/path/to/nvim/lua/plugins/neotest.lua
```
