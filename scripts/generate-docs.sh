#!/bin/sh
set -eu
: "${PANVIMDOC_DIR:=.dependencies/panvimdoc}"
if [ ! -f "$PANVIMDOC_DIR/panvimdoc.sh" ]; then
  git clone --depth 1 --branch v6.1.0 https://github.com/kdheepak/panvimdoc.git "$PANVIMDOC_DIR"
fi
mkdir -p doc
bash "$PANVIMDOC_DIR/panvimdoc.sh" --project-name neotest-cmake --input-file README.md \
  --vim-version 'Neovim >= 0.10' --description 'CMake GoogleTest adapter for Neotest' \
  --no-date true --treesitter true
