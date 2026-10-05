# Our fork's tooling (FORK.md). `just` lists the recipes.
default:
    @just --list

# Install ForeverAuras at a committed ref on the gaming box (default HEAD): just box-install [--ref <ref>] [--dry-run]
[positional-arguments]
box-install *args:
    @tools/box-install.sh "$@"

# What would change on the box, without writing anything
box-diff:
    @tools/box-install.sh --dry-run

# Pull upstream (neroxrw/foreverauras) into main, fast-forward only
sync-upstream:
    git fetch upstream && git merge --ff-only upstream/main
