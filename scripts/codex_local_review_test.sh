#!/usr/bin/env bash
# Tests for scripts/codex_local_review.sh's choice of codex binary: an empty or broken one is refused
# (exit 3) rather than run — a 0-byte binary left by an interrupted extension update ran, printed
# nothing and exited 0, which read as a review that found nothing — and the extension search skips
# empty copies for an older working one. Only the binary checks are asserted: they run before any git
# step, and a run that gets past them is stopped by --dry-run before codex is ever invoked.
set -uo pipefail
cd "$(dirname "$0")/.." || exit

pass=0
fail=0
check() { # check <name> <condition result 0/1> <detail>
	if [ "$2" = 0 ]; then
		pass=$((pass+1))
	else
		fail=$((fail+1))
		echo "FAIL: $1"
		echo "  $3"
	fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sys_path=/usr/bin:/bin # no codex on it

# run <home> [CODEX=...]: the script's exit code in $code, its stderr in $err
run() {
	local home=$1
	shift
	err=$(env -i PATH="$sys_path" HOME="$home" "$@" bash scripts/codex_local_review.sh --dry-run 2>&1 >/dev/null)
	code=$?
}

working() { # a stub that answers --version
	printf '#!/bin/sh\necho "codex-cli 0.0.0-test"\n' >"$1"
	chmod +x "$1"
}

# 1. $CODEX naming a 0-byte executable is refused, by name
: >"$tmp/empty-codex"
chmod +x "$tmp/empty-codex"
run "$tmp/home-none" CODEX="$tmp/empty-codex"
check "an empty \$CODEX is refused" "$([ "$code" = 3 ] && [[ "$err" == *"does not run"* ]] && echo 0 || echo 1)" "exit $code: $err"

# 2. $CODEX naming a binary that answers nothing to --version is refused
printf '#!/bin/sh\nexit 0\n' >"$tmp/mute-codex"
chmod +x "$tmp/mute-codex"
run "$tmp/home-none" CODEX="$tmp/mute-codex"
check "a silent \$CODEX is refused" "$([ "$code" = 3 ] && [[ "$err" == *"does not run"* ]] && echo 0 || echo 1)" "exit $code: $err"

# 3. the extension search skips a newer 0-byte copy for an older working one
ext="$tmp/home-ext/.vscode-server/extensions"
mkdir -p "$ext/openai.chatgpt-26.900.1-linux-x64/bin/linux-x86_64" "$ext/openai.chatgpt-26.930.1-linux-x64/bin/linux-x86_64"
working "$ext/openai.chatgpt-26.900.1-linux-x64/bin/linux-x86_64/codex"
: >"$ext/openai.chatgpt-26.930.1-linux-x64/bin/linux-x86_64/codex"
chmod +x "$ext/openai.chatgpt-26.930.1-linux-x64/bin/linux-x86_64/codex"
run "$tmp/home-ext"
check "an older working copy is chosen over a newer empty one" "$([ "$code" != 3 ] && echo 0 || echo 1)" "exit $code: $err"

# 4. only an empty copy: refused, not run
ext2="$tmp/home-empty/.vscode-server/extensions/openai.chatgpt-26.930.1-linux-x64/bin/linux-x86_64"
mkdir -p "$ext2"
: >"$ext2/codex"
chmod +x "$ext2/codex"
run "$tmp/home-empty"
check "an empty extension copy alone is refused" "$([ "$code" = 3 ] && [[ "$err" == *"no codex CLI found"* ]] && echo 0 || echo 1)" "exit $code: $err"

# 5. a working $CODEX gets past the checks
working "$tmp/good-codex"
run "$tmp/home-none" CODEX="$tmp/good-codex"
check "a working \$CODEX is accepted" "$([ "$code" != 3 ] && echo 0 || echo 1)" "exit $code: $err"

echo "codex_local_review_test: $pass passed, $fail failed"
[ "$fail" = 0 ]
