#!/usr/bin/env bash
# adx — agentic-developer-experience
#
# Idempotent bootstrap: ensure mise is installed, then let `mise bootstrap`
# install every tool and symlink every packaged config (see mise.toml).
# Safe to run repeatedly — each step converges and skips work already done.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Ensure mise is on PATH, installing it if missing.
if ! command -v mise >/dev/null 2>&1; then
	# The official installer is itself idempotent.
	echo "mise not found — installing from https://mise.run"
	curl -fsSL https://mise.run | sh
fi
# mise's default install location, in case the current shell hasn't picked it up.
export PATH="${MISE_INSTALL_PATH:-$HOME/.local/bin}:$PATH"
if ! command -v mise >/dev/null 2>&1; then
	echo "error: mise install did not land on PATH; open a new shell and re-run." >&2
	exit 1
fi

cd "$REPO_DIR"

# 2. Pre-link the global tools drop-in so `mise bootstrap` sees those tools in
#    its merged config and installs them GLOBALLY (active in every dir), in a
#    single run. bootstrap's [dotfiles] phase also tracks this link, so the
#    ln below is just an idempotent ordering guarantee.
mkdir -p "$HOME/.config/mise/conf.d"
ln -sfn "$REPO_DIR/mise/adx.toml" "$HOME/.config/mise/conf.d/adx.toml"

# 3. Trust this repo's config, then converge tools + config symlinks.
#    mise.toml pins `min_version`, so mise itself errors if it's too old to run
#    `mise bootstrap` / [dotfiles] (run `mise self-update` to upgrade).
#    --force-dotfiles lets the symlinks replace a pre-existing real
#    ~/.config/nvim directory; everything else is already idempotent.
mise trust -q
exec mise bootstrap --yes --force-dotfiles "$@"
