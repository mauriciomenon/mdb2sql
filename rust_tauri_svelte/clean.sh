#!/usr/bin/env bash
# "make clean": removes build intermediates. --dist also removes the products in dist/.
set -Eeuo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
    "") targets=() ;;
    --dist) targets=(dist) ;;
    *) echo "Usage: $0 [--dist]" >&2; exit 2 ;;
esac
# pnpm workspace node_modules (repo root and ui): linked to another store, pnpm install refuses; rebuilt from .tools
targets+=(target ui/dist dist/.stage ../node_modules ui/node_modules)

for target in "${targets[@]}"; do
    if [[ -e "$root_dir/$target" ]]; then
        rm -rf -- "${root_dir:?}/$target"
        echo "removed $root_dir/$target"
    fi
done
