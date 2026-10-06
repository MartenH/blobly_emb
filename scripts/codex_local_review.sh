#!/usr/bin/env bash
# A local codex review of this branch, run BEFORE `@codex review` is requested on the PR.
#
#   scripts/codex_local_review.sh            # gpt-6.1-sol, high effort, against origin/main
#   scripts/codex_local_review.sh --astra    # gpt-6-astra, xhigh (slower; for risky changes)
#   scripts/codex_local_review.sh --model M --effort E --base REF --dry-run
#   scripts/codex_local_review.sh --check-codex   # which codex it would run, and its version
#
# Reviews merge-base(REF, HEAD)..HEAD and refuses a dirty tree, because the review runs tests
# against the working tree and they must be the commits under review. Asks for EVERY defect,
# names the host gates this repo's CI runs, allows sockets in its sandbox (the example e2e tests
# use vcan and UDP), prints the findings, and keeps one transcript (and its findings) per run in
# the main checkout's .claude/reviews/.
#
# The codex CLI: $CODEX if set (it must run, or the script stops), else the first that runs of
# `codex` on PATH and the copies the VS Code extension bundles, newest first. "Runs" = executable
# and answering --version with something within 10 s: an interrupted extension update once left a
# 0-byte copy, which the old newest-first pick ran — it exited 0 with nothing written, and the
# review failed only as "codex wrote no final message", naming no cause.
#
# Exit: 0 reviewed; 1 setup failed; 2 usage; 3 no codex CLI that runs; 4 the review left the tree dirty or HEAD moved;
# otherwise codex's own failure, with the transcript's tail instead of findings.
set -eu

self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
cd "$(dirname "$self")/.."

usage() {
	sed -n '2,/^set -eu$/p' "$self" | sed '$d' | sed 's/^# \{0,1\}//'
}

model=gpt-6.1-sol
effort=high
base=origin/main
dry_run=0
check_codex=0
while [ $# -gt 0 ]; do
	case "$1" in
	--model | --effort | --base)
		if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
			echo "codex-local-review: $1 needs a value" >&2
			exit 2
		fi
		case "$1" in
		--model) model=$2 ;;
		--effort) effort=$2 ;;
		--base) base=$2 ;;
		esac
		shift 2
		;;
	--astra) model=gpt-6-astra; effort=xhigh; shift ;;
	--dry-run) dry_run=1; shift ;;
	--check-codex) check_codex=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) echo "codex-local-review: unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

# runs <path>: prints its --version (non-empty) when the binary runs; fails otherwise
runs() {
	local v
	[ -n "$1" ] && [ -f "$1" ] && [ -x "$1" ] || return 1
	v=$(timeout 10 "$1" --version </dev/null 2>/dev/null) || return 1
	[ -n "$v" ] || return 1
	printf '%s\n' "$v" | head -1
}

codex=
codex_version=
if [ -n "${CODEX:-}" ]; then
	if ! codex_version=$(runs "$CODEX"); then
		echo "codex-local-review: \$CODEX=$CODEX does not run (missing, empty or broken)" >&2
		exit 3
	fi
	codex=$CODEX
else
	while IFS= read -r candidate; do
		if codex_version=$(runs "$candidate"); then
			codex=$candidate
			break
		fi
		echo "codex-local-review: skipping $candidate: it does not run (empty or broken)" >&2
	done < <(
		command -v codex || true
		find "$HOME"/.vscode-server/extensions -path '*/openai.chatgpt-*/bin/*/codex' -type f 2>/dev/null | sort -rV || true
	)
	if [ -z "$codex" ]; then
		echo "codex-local-review: no codex CLI that runs (reload the Codex extension, or set CODEX=/path/to/codex)" >&2
		exit 3
	fi
fi
if [ "$check_codex" = 1 ]; then
	printf '%s\n%s\n' "$codex" "$codex_version"
	exit 0
fi

if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
	echo "codex-local-review: the working tree is not clean; commit or remove these first:" >&2
	git status --porcelain --untracked-files=normal >&2
	exit 1
fi
if [ "$base" = origin/main ] && ! git fetch -q origin; then
	echo "codex-local-review: could not fetch origin; refusing to review against a stale origin/main" >&2
	exit 1
fi
head=$(git rev-parse HEAD)
merge_base=$(git merge-base "$base" "$head")

# The V this build uses: $V (a command and its flags, as scripts/build_tool.sh takes it), else `v`
# on PATH. It need not match the CI pin (.v-version) — `make v-pin` says how it differs — so the
# review is told which one it is running.
read -r -a v_cmd <<< "${V:-v}"
v_bin=$(command -v "${v_cmd[0]:-v}" || true)
v_run=${V:-$v_bin}
probe_note="Put any probe or scratch files under /tmp, never in the repository."
gates="the host unit tests \`$v_run -enable-globals test <module>/\` for the touched modules (CI runs comm driver tools ecu loom nvm wdg bcrypto boot, and examples), \`make lint\` (no-alloc + isolation, must pass), \`make check\`, \`make syscheck SYSTEM=<file>\` for each examples/*/system.toml the change can affect (the cross-node checks; a bare \`make syscheck\` checks only examples/system_bench, CI loops over every one) and \`make trace-check\`; and build every example the change can affect as CI's loop does (\`make -C <dir> all\` for a host example, \`make -C <dir> gen\` for a cross one, generated outputs unchanged afterwards), since \`v test examples\` compiles only the examples that have tests. tools/vectab needs the CMSIS headers under third_party/; if they are absent, skip it rather than fetching them. Do not flash or touch hardware (never \`make hwtest\` or \`make flash\`)"
if [ -n "$v_bin" ] && [ -x "$v_bin" ]; then
	v_note="The V compiler is \`$v_run\` ($("$v_bin" version 2>/dev/null || echo 'version unknown'); CI pins $(tr -d '[:space:]' < .v-version)). Do not look for other V installations. Where they bear on the change, run $gates. A change to generated code must leave \`gen/\` outputs that regeneration reproduces. Network sockets are allowed, so the UDP/TCP tests can run. $probe_note"
else
	v_note="No V compiler was found on this machine; review statically and say that tests were not run. $probe_note"
	echo "codex-local-review: warning: no V in \$V or on PATH; the review will not run tests" >&2
fi

prompt="Review the changes on this branch: \`git diff $merge_base $head\`.

Report EVERY defect you find, not only the most important ones. Include minor ones and edge cases: wire-level and protocol behaviour, inputs at or past their limits, timing and deadlines, error paths, data that is accepted and then lost or silently altered, and inconsistencies between what an API accepts and what it can actually do. Do not filter for importance or for how likely the case is; the author triages. Exclude pure style with no behavioural consequence, and values no caller could plausibly pass (an integer near its type's overflow) unless they arrive from outside (a file, the wire, a config).

For each finding give a priority (P1/P2/P3), the file and line range, and a concrete scenario: the input or state, and the wrong result.

$v_note"

reviews=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)/.claude/reviews
branch=$(git symbolic-ref --quiet --short HEAD || echo detached)
name="local-$branch-${head:0:9}-$model-$effort-$(date +%Y%m%d-%H%M%S)-$$"
out=$reviews/${name//[^A-Za-z0-9._-]/-}.txt
findings=${out%.txt}.findings.md
cmd=("$codex" exec review - --output-last-message "$findings"
	-c "model=$model" -c "review_model=$model" -c "model_reasoning_effort=$effort"
	-c 'sandbox_mode="workspace-write"'
	-c sandbox_workspace_write.network_access=true
	-c "sandbox_workspace_write.writable_roots=[\"$HOME/.vmodules/.cache\"]")

if [ "$dry_run" = 1 ]; then
	printf '%q ' "${cmd[@]}"
	printf '\n\n%s\n' "$prompt"
	exit 0
fi

mkdir -p "$reviews" "$HOME/.vmodules/.cache" # a writable root that does not exist stops the sandbox
# Whatever the review's outcome, a working tree it changed must not pass unnoticed: a moved HEAD or
# a dirty tree is exit 4 even when the review itself also failed.
dirty_check() {
	rc=$?
	if [ "$(git rev-parse HEAD)" != "$head" ]; then
		echo "codex-local-review: HEAD moved during the review; these findings are for ${head:0:9}, not the branch as it is now" >&2
		rc=4
	fi
	if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
		echo "codex-local-review: the review left the working tree dirty; inspect before committing:" >&2
		git status --porcelain --untracked-files=normal >&2
		rc=4
	fi
	exit "$rc"
}
trap dirty_check EXIT
echo "codex-local-review: $model ($effort) on ${head:0:9} against $base, $codex_version; transcript: $out" >&2
start=$(date +%s)
status=0
printf '%s\n' "$prompt" | "${cmd[@]}" > "$out" 2>&1 || status=$?
echo "codex-local-review: finished in $(( $(date +%s) - start )) s, exit $status" >&2

if [ "$status" != 0 ]; then
	echo "codex-local-review: the review did NOT complete; these are not findings. Transcript tail:" >&2
	tail -20 "$out" >&2
	exit "$status"
fi
if [ ! -s "$findings" ]; then
	echo "codex-local-review: codex wrote no final message; see the transcript" >&2
	exit 1
fi
cat "$findings"
echo
