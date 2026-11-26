#!/bin/sh
set -eu
mkdir -p .dependencies
for name in neotest nvim-nio plenary.nvim; do
  case "$name" in
    plenary.nvim) owner=nvim-lua ;;
    *) owner=nvim-neotest ;;
  esac
  if [ ! -d ".dependencies/$name" ]; then
    git clone --depth 1 "https://github.com/$owner/$name.git" ".dependencies/$name"
  fi
done
