# neotest-cmake

A [neotest](https://github.com/nvim-neotest/neotest) adapter for CMake projects using GoogleTest. Adapted from [cmake-tests.nvim](https://github.com/mjrogozinski/cmake-tests.nvim), retaining its CTest execution model and GoogleTest/JUnit parsers.

- Discover `TEST`, `TEST_F`, `TEST_P`, `TYPED_TEST`, and `TYPED_TEST_P` definitions with the C++ Tree-sitter parser.
- Match source definitions to compiled test names, including value parameters and typed instantiations.
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

Rebuild after source changes. The adapter deliberately uses the existing build; it does not configure, build, fetch dependencies, or choose presets automatically.

## Configuration

```lua
require('neotest-cmake')({
  build_dir = 'build',
  config = '',
  jobs = 1,
  ctest = 'ctest',
  discovery_timeout = 10000, -- milliseconds per discovery process
  ctest_args = {},          -- additional CTest execution options
  frameworks = {},          -- executable absolute path/basename -> 'gtest' or 'ctest'
  -- root = '/path/to/project', -- or function(path) -> root
})
```

The root is found using CMakePresets.json or .git, falling back to CMakeLists.txt. Set `root` explicitly for nested projects. `build_dir` may also be a function of the root. Supply the preset's binary directory explicitly when using presets. Configuration is shared by this adapter instance.

Unknown executables are never launched to guess their framework. GoogleTest detection scans static flag strings and shared-library dependency names (up to 64 MiB), including Nix-linked dylibs; use `frameworks` for unusual binaries. Enumeration reuses the registration's command, existing GoogleTest filter, working directory, and `ENVIRONMENT` properties. Registered executables run through CTest; unregistered File API targets run directly from the build directory. Executables already referenced by CTest commands are excluded from direct discovery to preserve their registration semantics.

## Build integration

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

CTest registrations are the execution boundary. For `gtest_discover_tests()`, selecting a source test selects its concrete registrations; parameterized/typed definitions aggregate all matching instantiations. With `add_test(NAME ... COMMAND executable)`, selecting any case runs the entire registration. Individual case output determines results inside a failed group. CTest may also run fixture setup and cleanup registrations.

Unregistered targets support exact case/file selection, including all matching parameterized and typed instantiations. Mixed selections run a CTest batch and each unregistered binary sequentially within one neotest process, keeping captured output and results separate for each command. A clean headless Neovim process runs these commands without loading your configuration. Direct targets have no CTest fixture or environment properties; register them with CTest if they require those launch settings. `extra_args` are passed to CTest for registered runs and to the executable for direct runs.

Qt Test, custom test macros, generated definitions without source positions, and debugger/DAP execution are outside this adapter's current scope. Source discovery does not preprocess C++, so conditional compilation can leave unmatched definitions, which are reported as skipped in a selected file.

Custom launchers and `ENVIRONMENT_MODIFICATION` requirements can prevent enumeration: these CTest properties are preserved during execution but are not reproduced during direct `--gtest_list_tests` discovery. Such registrations may not match source tests. Duplicate suite/case names in different executables select all matching registrations. GoogleTest output must use its normal text format for detailed results inside whole-executable registrations. Missing JUnit results are failures, never inferred successes.

## Development

With GoogleTest installed and discoverable by CMake:

```sh
make test
```

The tests use real neotest trees, real CTest processes, and compiled GoogleTest fixtures. They verify source discovery, false positives in comments/strings, parameterized and typed cases, passes/failures/skips/disabled tests, exact selection, regex escaping in registration names, grouped results, environment preservation, fixture cleanup, expected failures, skip rules, timeouts, missing reports, unregistered binary discovery, exact direct selection, multiple executables, and mixed registered/direct runs.

The test runner finds neotest, nvim-nio, and plenary.nvim under `~/.local/share/nvim/lazy` by default. Override `NEOTEST_DEPS` with a directory containing those checkouts. `CPP_PARSER_DIR` can point to a runtime directory containing `parser/cpp.so`. Set `CMAKE_PREFIX_PATH` if GoogleTest is installed outside your CMake search path.

MIT licensed. The original cmake-tests.nvim copyright is retained in LICENSE.
