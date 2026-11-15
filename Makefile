NVIM ?= nvim
CMAKE ?= cmake

.PHONY: fixture test
fixture:
	mkdir -p build/fixture/.cmake/api/v1/query
	touch build/fixture/.cmake/api/v1/query/codemodel-v2
	$(CMAKE) -S tests/fixture -B build/fixture
	$(CMAKE) --build build/fixture --parallel 2
test: fixture
	$(NVIM) --headless -i NONE -u tests/init.lua '+luafile tests/run.lua'
