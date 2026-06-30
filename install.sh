#!/usr/bin/env bash
# workspace
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
ln -sfn "$REPO_DIR/mise/workspace.toml" "$HOME/.config/mise/conf.d/workspace.toml"

# 3. Trust this repo's config, then converge tools + config symlinks.
#    mise.toml pins `min_version`, so mise itself errors if it's too old to run
#    `mise bootstrap` / [dotfiles] (run `mise self-update` to upgrade).
#    --force-dotfiles lets the symlinks replace a pre-existing real
#    ~/.config/nvim directory; everything else is already idempotent. Any such
#    real file is backed up first (see step 3b) so nothing is lost.
mise trust -q

# 3a. Inspect the full plan and decide whether there's anything to do.
#     `bootstrap status` lists every managed dotfile (source -> target) and
#     tool, with a state in the last column: converged items read `applied`
#     (dotfiles) or `installed` (tools); anything else (missing, conflict, …)
#     means work is pending. We classify from that last token — any
#     unexpected/non-converged value counts as pending, which is the safe
#     direction (at worst we prompt when we didn't strictly need to).
plan="$(mise bootstrap status "$@")"

pending=0
while IFS= read -r line; do
	[ -z "$line" ] && continue
	case "${line##* }" in
	applied | installed) ;;
	*) pending=1 ;;
	esac
done <<EOF
$plan
EOF

# Nothing to converge — exit cleanly without nagging for confirmation.
if [ "$pending" -eq 0 ]; then
	echo "workspace: already up to date — nothing to apply."
	exit 0
fi

# Otherwise show the plan (no changes yet) and gate the real run below.
echo "== bootstrap plan (no changes will be made yet) =="
printf '%s\n' "$plan"
echo "================================================="

# Skip the prompt for unattended runs: set WORKSPACE_ASSUME_YES=1, or when
# there's no terminal to ask on (e.g. piped). Otherwise require an explicit y.
if [ "${WORKSPACE_ASSUME_YES:-}" != "1" ] && [ -e /dev/tty ]; then
	printf 'Apply the changes above? [y/N] '
	read -r reply </dev/tty
	case "$reply" in
	[yY] | [yY][eE][sS]) ;;
	*)
		echo "aborted — no changes made." >&2
		exit 1
		;;
	esac
fi

# 3b. Back up anything that would be clobbered. A `differs` state means a real
#     file/dir already lives at a target where we expect a symlink, and
#     --force-dotfiles would replace it. Move each such target aside to a
#     timestamped sibling (matching the existing `*.bak-<ts>` convention) so
#     nothing is ever lost; mise then creates the link in its place. Only
#     `differs` needs this — `missing` has nothing to save and `applied` is
#     already the link. Runs for both the prompted and WORKSPACE_ASSUME_YES
#     paths, since by here we've committed to applying.
ts="$(date +%Y%m%d-%H%M%S)"
while IFS= read -r line; do
	case "$line" in
	dotfiles*differs*) ;;
	*) continue ;;
	esac
	# Column 2 is the target path; expand a leading ~ to $HOME.
	read -r _ target _ <<<"$line"
	target="${target/#\~/$HOME}"
	if [ -e "$target" ] && [ ! -L "$target" ]; then
		echo "backing up $target -> ${target}.bak-${ts}"
		mv "$target" "${target}.bak-${ts}"
	fi
done <<EOF
$plan
EOF

# 3c. Apply for real.
exec mise bootstrap --yes --force-dotfiles "$@"
