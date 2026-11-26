NVIM ?= nvim
CMAKE ?= cmake

.PHONY: fixture test
fixture:
	mkdir -p build/fixture/.cmake/api/v1/query
	touch build/fixture/.cmake/api/v1/query/codemodel-v2
	$(CMAKE) -S tests/fixture -B build/fixture
	$(CMAKE) --build build/fixture --parallel 2
test: fixture
	$(NVIM) --headless -i NONE -u tests/init.lua '+luafile tests/health.lua'
	$(NVIM) --headless -i NONE -u tests/init.lua '+luafile tests/parsers.lua'
	$(NVIM) --headless -i NONE -u tests/init.lua '+luafile tests/activity.lua'
	$(NVIM) --headless -i NONE -u tests/init.lua '+luafile tests/startup.lua'
	$(NVIM) --headless -i NONE -u tests/init.lua '+luafile tests/source.lua'
	$(NVIM) --headless -i NONE -u tests/init.lua '+luafile tests/diagnostics.lua'
	$(NVIM) --headless -i NONE -u tests/init.lua '+luafile tests/run.lua'
	$(NVIM) --headless -i NONE -u tests/init.lua '+luafile tests/neotest.lua'
	$(NVIM) --headless -i NONE -u tests/init.lua '+luafile tests/overseer.lua'

STYLUA ?= stylua
LUACHECK ?= luacheck
LUA_LANGUAGE_SERVER ?= lua-language-server

.PHONY: format check-format lint types download-dependencies check check-tools
format:
	$(STYLUA) lua tests
check-format:
	$(STYLUA) --check lua tests
lint:
	$(LUACHECK) lua tests
download-dependencies:
	sh scripts/download-dependencies.sh
types: download-dependencies
	NVIM="$(NVIM)" LUA_LANGUAGE_SERVER="$(LUA_LANGUAGE_SERVER)" sh scripts/check-types.sh
# A launcher cannot export its environment back into the calling terminal.
# Keep plain `make check` usable when development tools are supplied by Nix.
check:
	@if command -v "$(STYLUA)" >/dev/null 2>&1 && \
	    command -v "$(LUACHECK)" >/dev/null 2>&1 && \
	    command -v "$(LUA_LANGUAGE_SERVER)" >/dev/null 2>&1 && \
	    command -v "$(NVIM)" >/dev/null 2>&1; then \
	  $(MAKE) check-tools; \
	elif command -v nix >/dev/null 2>&1; then \
	  printf '%s\n' 'Development tools missing; running checks in the Nix shell.'; \
	  nix develop "path:$(CURDIR)" --command make check-tools; \
	else \
	  printf '%s\n' 'Install StyLua, Luacheck, LuaLS and Neovim, or install Nix to use the pinned development shell.' >&2; \
	  exit 1; \
	fi
check-tools: check-format lint types

.PHONY: docs check-docs
docs:
	sh scripts/generate-docs.sh
check-docs: docs
	git diff --exit-code -- doc/neotest-cmake.txt
