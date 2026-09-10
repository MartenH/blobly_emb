#!/usr/bin/env bash
# Fixture tests for scripts/codex_review.py. The fake gh emits GitHub-shaped
# JSON so the watcher exercises JSON parsing, pagination, baselines, actor
# checks, SHA matching, request persistence, and exit-code classification.
set -uo pipefail
cd "$(dirname "$0")/.." || exit

pass=0
fail=0
ok() {
	if [ "$2" = "$3" ]; then
		pass=$((pass+1))
	else
		fail=$((fail+1))
		echo "FAIL: $1"
		echo "  want: $3"
		echo "  got:  $2"
	fi
}

stub=$(mktemp -d)
trap 'rm -rf "$stub"' EXIT

cat >"$stub/git" <<'GIT'
#!/usr/bin/env bash
if [ "$1" = rev-parse ] && [ "${2:-}" = HEAD ]; then
	printf '%s\n' "${FAKE_GIT_HEAD_SHA:-abcdef1234567890abcdef1234567890abcdef12}"
	exit 0
fi
if [ "$1" = status ] && [ "${2:-}" = --porcelain ]; then
	if [ "${FAKE_GIT_DIRTY:-}" = 1 ]; then
		printf ' M scripts/codex_review.py\n'
	fi
	exit 0
fi
if [ "$1" = config ] && [ "${2:-}" = --get ] && [ "${3:-}" = remote.origin.url ]; then
	printf '%s\n' "${FAKE_GIT_ORIGIN:-git@github.com:MartenH/blobly_net}"
	exit 0
fi
exec /usr/bin/git "$@"
GIT
chmod +x "$stub/git"

cat >"$stub/gh" <<'GH'
#!/usr/bin/env bash
endpoint=
paginate=0
head_sha=${FAKE_GH_HEAD_SHA:-abcdef1234567890abcdef1234567890abcdef12}
[ "${FAKE_GH_CASE:-}" = stale_head ] && head_sha=fedcba9876543210fedcba9876543210fedcba98

if [ "$1" = pr ] && [ "$2" = view ]; then
	[ "${FAKE_GH_CASE:-}" = request_head_fail ] && exit 4
	printf '%s\n' "$head_sha"
	exit 0
fi

if [ "$1" = pr ] && [ "$2" = comment ]; then
	if [ "${FAKE_GH_CASE:-}" = request_success ] || [ "${FAKE_GH_CASE:-}" = request_timestamp_fail ] ||
		[ "${FAKE_GH_CASE:-}" = remote_spoof ] || [ "${FAKE_GH_CASE:-}" = alt_actor_clean ] ||
		[ "${FAKE_GH_CASE:-}" = remote_pending ]; then
		repo=
		while [ "$#" -gt 0 ]; do
			case "$1" in
				--repo) repo=$2; shift 2 ;;
				*) shift ;;
			esac
		done
		[ "$repo" = MartenH/blobly_net ] || { echo "wrong repo: $repo" >&2; exit 8; }
		printf 'https://github.com/MartenH/blobly_net/pull/123#issuecomment-999\n'
		exit 0
	fi
	echo "unexpected review request post" >&2
	exit 8
fi

for arg in "$@"; do
	case "$arg" in
		repos/*) endpoint=$arg ;;
		user) endpoint=$arg ;;
		--paginate) paginate=1 ;;
	esac
done

if [ "${FAKE_GH_CASE:-}" = api_flaky ]; then
	_n=$(cat "$(dirname "$0")/flaky" 2>/dev/null || echo 0)
	_n=$((_n + 1))
	printf '%s' "$_n" >"$(dirname "$0")/flaky"
	if [ "$_n" -le 1 ]; then
		echo "simulated 502 from the API" >&2
		exit 1
	fi
fi

if [ "$endpoint" = user ]; then
	printf '{"login":"MartenH"}\n'
	exit 0
fi

if [ "$endpoint" = repos/MartenH/blobly_net/pulls/123 ]; then
	[ "${FAKE_GH_CASE:-}" = hang ] && sleep 2
	printf '{"head":{"sha":"%s"}}\n' "$head_sha"
	exit 0
fi

if [ "$endpoint" = repos/MartenH/blobly_net/issues/comments/999 ]; then
	[ "${FAKE_GH_CASE:-}" = request_timestamp_fail ] && exit 4
	printf '{"created_at":"2026-01-01T00:00:02Z"}\n'
	exit 0
fi

[ "$paginate" -eq 1 ] || { echo "missing --paginate" >&2; exit 9; }
bot='{"login":"chatgpt-codex-connector[bot]"}'
alt='{"login":"alt-bot"}'
human='{"login":"human"}'

case "${FAKE_GH_CASE:-}:$endpoint" in
	clean:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[{"id":10,"submitted_at":"2026-01-01T00:00:00Z","user":%s,"body":"old review **Reviewed commit:** `aaaaaaaaaa`"}]\n' "$bot"
		;;
	clean:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	clean:repos/MartenH/blobly_net/issues/123/comments)
		printf '[{"id":41,"created_at":"2026-01-01T00:00:02Z","user":%s,"body":"Done. Didn'\''t find any major issues. **Reviewed commit:** `abcdef1234`"}]\n' "$bot"
		;;
	clean_with_findings:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[{"id":10,"submitted_at":"2026-01-01T00:00:00Z","user":%s,"body":"old review **Reviewed commit:** `aaaaaaaaaa`"}]\n' "$bot"
		;;
	clean_with_findings:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[{"id":31,"created_at":"2026-01-01T00:00:02Z","user":%s,"body":"inline issue","commit_id":"abcdef1234567890abcdef1234567890abcdef12","original_commit_id":"abcdef1234567890abcdef1234567890abcdef12"}]\n' "$bot"
		;;
	clean_with_findings:repos/MartenH/blobly_net/issues/123/comments)
		printf '[{"id":41,"created_at":"2026-01-01T00:00:02Z","user":%s,"body":"Done. Didn'\''t find any major issues. **Reviewed commit:** `abcdef1234`"}]\n' "$bot"
		;;
	api_flaky:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[{"id":10,"submitted_at":"2026-01-01T00:00:00Z","user":%s,"body":"old review **Reviewed commit:** `aaaaaaaaaa`"}]\n' "$bot"
		;;
	api_flaky:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	api_flaky:repos/MartenH/blobly_net/issues/123/comments)
		printf '[{"id":41,"created_at":"2026-01-01T00:00:02Z","user":%s,"body":"Done. Didn'\''t find any major issues. **Reviewed commit:** `abcdef1234`"}]\n' "$bot"
		;;
	clean_alt:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[]\n'
		;;
	clean_alt:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	clean_alt:repos/MartenH/blobly_net/issues/123/comments)
		printf '[{"id":44,"created_at":"2026-01-01T00:00:02Z","user":%s,"body":"No blocking defects found. **Reviewed commit:** `abcdef1234`"}]\n' "$bot"
		;;
	clean_review_body:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[{"id":11,"submitted_at":"2026-01-01T00:00:02Z","user":%s,"body":"Codex Review: Didn'\''t find any major issues. **Reviewed commit:** `abcdef1234`"}]\n' "$bot"
		;;
	clean_review_body:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	clean_review_body:repos/MartenH/blobly_net/issues/123/comments)
		printf '[]\n'
		;;
	findings:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[{"id":11,"submitted_at":"2026-01-01T00:00:02Z","user":%s,"body":"Here are suggestions. **Reviewed commit:** `abcdef1234`"}]\n' "$bot"
		;;
	findings:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[{"id":31,"created_at":"2026-01-01T00:00:02Z","user":%s,"body":"inline issue","commit_id":"abcdef1234567890abcdef1234567890abcdef12","original_commit_id":"abcdef1234567890abcdef1234567890abcdef12"}]\n' "$bot"
		;;
	findings:repos/MartenH/blobly_net/issues/123/comments)
		printf '[]\n'
		;;
	findings_no_footer:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[{"id":11,"submitted_at":"2026-01-01T00:00:02Z","user":%s,"body":"### Codex Review https://github.com/MartenH/blobly_net/blob/abcdef1234567890abcdef1234567890abcdef12/tools/x.v#L1-L2 **P1 Badge** a finding in the body"}]\n' "$bot"
		;;
	findings_no_footer:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[{"id":31,"created_at":"2026-01-01T00:00:02Z","user":%s,"body":"inline issue","commit_id":"abcdef1234567890abcdef1234567890abcdef12","original_commit_id":"abcdef1234567890abcdef1234567890abcdef12"}]\n' "$bot"
		;;
	findings_no_footer:repos/MartenH/blobly_net/issues/123/comments)
		printf '[]\n'
		;;
	stale_body_no_footer:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[{"id":11,"submitted_at":"2026-01-01T00:00:02Z","user":%s,"body":"### Codex Review https://github.com/MartenH/blobly_net/blob/999999999999999999999999999999999999beef/tools/x.v#L1-L2 **P1 Badge** a finding for another commit"}]\n' "$bot"
		;;
	stale_body_no_footer:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	stale_body_no_footer:repos/MartenH/blobly_net/issues/123/comments)
		printf '[]\n'
		;;
	stale_inline_clean:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[{"id":11,"submitted_at":"2026-01-01T00:00:02Z","user":%s,"body":"Codex Review: Didn'\''t find any major issues. **Reviewed commit:** `abcdef1234`"}]\n' "$bot"
		;;
	stale_inline_clean:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[{"id":31,"created_at":"2026-01-01T00:00:00Z","user":%s,"body":"old inline issue","commit_id":"abcdef1234567890abcdef1234567890abcdef12","original_commit_id":"abcdef1234567890abcdef1234567890abcdef12"}]\n' "$bot"
		;;
	stale_inline_clean:repos/MartenH/blobly_net/issues/123/comments)
		printf '[]\n'
		;;
	alt_actor_clean:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[{"id":11,"submitted_at":"2026-01-01T00:00:02Z","user":%s,"body":"Codex Review: Didn'\''t find any major issues. **Reviewed commit:** `abcdef1234`"}]\n' "$alt"
		;;
	alt_actor_clean:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	alt_actor_clean:repos/MartenH/blobly_net/issues/123/comments)
		printf '[]\n'
		;;
	body_only:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[{"id":12,"submitted_at":"2026-01-01T00:00:02Z","user":%s,"body":"P2 body-only issue /blob/abcdef1234567890/file.v#L44 **Reviewed commit:** `abcdef1234`"}]\n' "$bot"
		;;
	body_only:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	body_only:repos/MartenH/blobly_net/issues/123/comments)
		printf '[]\n'
		;;
	foreign_review:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[{"id":14,"submitted_at":"2026-01-01T00:00:02Z","user":%s,"body":"Human note linking /blob/abcdef1234567890/file.v#L44 without a reviewed marker"}]\n' "$human"
		;;
	foreign_review:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	foreign_review:repos/MartenH/blobly_net/issues/123/comments)
		printf '[]\n'
		;;
	spoof_review:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[{"id":16,"submitted_at":"2026-01-01T00:00:02Z","user":%s,"body":"Looks important. **Reviewed commit:** `abcdef1234`"}]\n' "$human"
		;;
	spoof_review:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	spoof_review:repos/MartenH/blobly_net/issues/123/comments)
		printf '[]\n'
		;;
	foreign_clean:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[]\n'
		;;
	foreign_clean:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	foreign_clean:repos/MartenH/blobly_net/issues/123/comments)
		printf '[{"id":43,"created_at":"2026-01-01T00:00:02Z","user":%s,"body":"Didn'\''t find any major issues while discussing abcdef1234, but no marker here."}]\n' "$human"
		;;
	spoof_clean:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[]\n'
		;;
	spoof_clean:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	spoof_clean:repos/MartenH/blobly_net/issues/123/comments)
		printf '[{"id":46,"created_at":"2026-01-01T00:00:02Z","user":%s,"body":"Done. **Reviewed commit:** `abcdef1234`"}]\n' "$human"
		;;
	split_marker_sha:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[]\n'
		;;
	split_marker_sha:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	split_marker_sha:repos/MartenH/blobly_net/issues/123/comments)
		printf '[{"id":45,"created_at":"2026-01-01T00:00:02Z","user":%s,"body":"Looks clean. Reviewed commit: `ffffffffff`; see also abcdef1234 elsewhere."}]\n' "$bot"
		;;
	remote_pending:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[]\n'
		;;
	remote_pending:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	remote_pending:repos/MartenH/blobly_net/issues/123/comments)
		printf '[{"id":998,"created_at":"2026-01-01T00:00:02Z","user":{"login":"MartenH"},"body":"@codex review\\n\\ncodex-review-state: abcdef1234567890abcdef1234567890abcdef12"}]\n'
		;;
	unanswered:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[{"id":31,"path":"a.v","line":1,"user":%s,"body":"answered finding"},{"id":32,"path":"b.v","line":2,"user":%s,"body":"open finding"},{"id":33,"user":{"login":"MartenH"},"in_reply_to_id":31,"body":"my reply"},{"id":34,"path":"c.v","line":3,"user":%s,"body":"a human comment"}]\n' "$bot" "$bot" "$human"
		;;
	remote_spoof:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[]\n'
		;;
	remote_spoof:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	remote_spoof:repos/MartenH/blobly_net/issues/123/comments)
		printf '[{"id":997,"created_at":"2026-01-01T00:00:02Z","user":%s,"body":"note codex-review-state: abcdef1234567890abcdef1234567890abcdef12"}]\n' "$human"
		;;
	early_same_sha:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[{"id":15,"submitted_at":"2026-01-01T00:00:00Z","user":%s,"body":"Old same-SHA result **Reviewed commit:** `abcdef1234`"}]\n' "$bot"
		;;
	early_same_sha:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	early_same_sha:repos/MartenH/blobly_net/issues/123/comments)
		printf '[]\n'
		;;
	old_sha:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[{"id":13,"submitted_at":"2026-01-01T00:00:02Z","user":%s,"body":"Done. **Reviewed commit:** `ffffffffff`"}]\n' "$bot"
		;;
	old_sha:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	old_sha:repos/MartenH/blobly_net/issues/123/comments)
		printf '[{"id":41,"created_at":"2026-01-01T00:00:02Z","user":%s,"body":"Done. Didn'\''t find any major issues. **Reviewed commit:** `ffffffffff`"}]\n' "$bot"
		;;
	failed:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '[]\n'
		;;
	failed:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	failed:repos/MartenH/blobly_net/issues/123/comments)
		printf '[{"id":42,"created_at":"2026-01-01T00:00:02Z","user":%s,"body":"Something went wrong while reviewing this pull request."}]\n' "$bot"
		;;
	ghfail:repos/MartenH/blobly_net/pulls/123/reviews)
		exit 4
		;;
	ghfail:repos/MartenH/blobly_net/pulls/123/comments)
		printf '[]\n'
		;;
	ghfail:repos/MartenH/blobly_net/issues/123/comments)
		printf '[]\n'
		;;
	*)
		printf '[]\n'
		;;
esac
GH
chmod +x "$stub/gh"

nogh=$(mktemp -d)
cat >"$nogh/gh" <<'GH'
#!/usr/bin/env bash
echo "command not found: gh" >&2
exit 127
GH
chmod +x "$nogh/gh"

run_case() {
	_case=$1
	_path=$2
	FAKE_GH_CASE=$_case PATH="$stub:/usr/bin:/bin" \
		bash scripts/codex_review_watch.sh --once --pr 123 --repo MartenH/blobly_net \
		--sha abcdef1234567890abcdef1234567890abcdef12 \
		--baseline-review-id 10 \
		--baseline-pull-comment-id 30 \
		--baseline-issue-comment-id 40 \
		--baseline-failure-comment-id 40 \
		--requested-at 2026-01-01T00:00:01Z \
		--interval 1 \
		--timeout 1 \
		>"$_path" 2>&1
	printf '%s' "$?"
}

out=$(mktemp)
rc=$(run_case clean "$out")
ok "clean exits 0" "$rc" "0"
ok "clean result" "$(grep -c '^RESULT=clean$' "$out")" "1"

rc=$(run_case clean_alt "$out")
ok "alternate clean prose exits 0" "$rc" "0"
ok "alternate clean prose result" "$(grep -c '^RESULT=clean$' "$out")" "1"

rc=$(run_case clean_review_body "$out")
ok "clean review body exits 0" "$rc" "0"
ok "clean review body result" "$(grep -c '^RESULT=clean$' "$out")" "1"

rc=$(run_case findings "$out")
ok "findings exits 20" "$rc" "20"
ok "findings counts inline comments" "$(grep -c '^PULL_COMMENTS=1$' "$out")" "1"

# emb#276 round 6: findings, but the review body carried no "Reviewed commit:" footer --
# only a /blob/<sha> permalink. Requiring the footer reported `pending` on a round that had
# already posted five findings.
rc=$(run_case findings_no_footer "$out")
ok "review body citing the sha without a footer exits 20" "$rc" "20"
ok "review body citing the sha counts inline comments" "$(grep -c '^PULL_COMMENTS=1$' "$out")" "1"

# ...and the looser match stays anchored: a body naming a DIFFERENT commit is not this round.
rc=$(run_case stale_body_no_footer "$out")
ok "review body citing another sha stays pending" "$rc" "1"
ok "review body citing another sha result" "$(grep -c '^RESULT=pending$' "$out")" "1"

# The verdict and the findings arrive on DIFFERENT channels, so a clean summary on the issues
# channel proves nothing on its own -- inline findings outrank it. A false clean merges
# unreviewed code, which is the one direction that must never be loosened.
rc=$(run_case clean_with_findings "$out")
ok "clean verdict with fresh inline findings exits 20" "$rc" "20"
ok "clean verdict with fresh inline findings result" "$(grep -c '^RESULT=findings$' "$out")" "1"

# One 502 in a ~200-call hour must not end the round unread.
rm -f "$stub/flaky"
FAKE_GH_CASE=api_flaky PATH="$stub:/usr/bin:/bin" \
	bash scripts/codex_review_watch.sh --pr 123 --repo MartenH/blobly_net \
	--sha abcdef1234567890abcdef1234567890abcdef12 \
	--baseline-review-id 10 --baseline-pull-comment-id 30 \
	--baseline-issue-comment-id 40 --baseline-failure-comment-id 40 \
	--requested-at 2026-01-01T00:00:01Z --interval 1 --timeout 20 >"$out" 2>&1
rc=$?
ok "a transient API failure is retried, not fatal" "$rc" "0"
ok "the retry is announced" "$(grep -c 'transient API failure, retrying' "$out")" "1"

# ...but a hard failure is not retried: --once still reports EXIT_API rather than gh's status.
rm -f "$stub/flaky"

rc=$(run_case stale_inline_clean "$out")
ok "old inline comments do not taint fresh clean review" "$rc" "0"
ok "old inline comments fresh clean result" "$(grep -c '^RESULT=clean$' "$out")" "1"

rc=$(run_case body_only "$out")
ok "body-only findings still exit 20" "$rc" "20"
ok "body-only has zero inline comments" "$(grep -c '^PULL_COMMENTS=0$' "$out")" "1"

rc=$(run_case foreign_review "$out")
ok "foreign review mentioning SHA is pending" "$rc" "1"
ok "foreign review does not claim findings" "$(grep -c '^RESULT=findings$' "$out")" "0"

rc=$(run_case spoof_review "$out")
ok "non-Codex review with marker is pending" "$rc" "1"
ok "non-Codex review with marker does not claim findings" "$(grep -c '^RESULT=findings$' "$out")" "0"

rc=$(run_case foreign_clean "$out")
ok "foreign clean wording without marker is pending" "$rc" "1"
ok "foreign clean does not claim clean" "$(grep -c '^RESULT=clean$' "$out")" "0"

rc=$(run_case spoof_clean "$out")
ok "non-Codex clean marker is pending" "$rc" "1"
ok "non-Codex clean marker does not claim clean" "$(grep -c '^RESULT=clean$' "$out")" "0"

rc=$(run_case split_marker_sha "$out")
ok "split marker and SHA is pending" "$rc" "1"
ok "split marker and SHA does not claim clean" "$(grep -c '^RESULT=clean$' "$out")" "0"

rc=$(run_case early_same_sha "$out")
ok "same-SHA result before request marker is pending" "$rc" "1"
ok "same-SHA early result does not claim findings" "$(grep -c '^RESULT=findings$' "$out")" "0"

rc=$(run_case old_sha "$out")
ok "old SHA result is pending" "$rc" "1"
ok "old SHA does not claim clean" "$(grep -c '^RESULT=clean$' "$out")" "0"

rc=$(run_case stale_head "$out")
ok "changed PR head exits 40" "$rc" "40"
ok "changed PR head result" "$(grep -c '^RESULT=stale_head$' "$out")" "1"

rc=$(run_case failed "$out")
ok "fresh failure exits 30" "$rc" "30"
ok "fresh failure result" "$(grep -c '^RESULT=failed$' "$out")" "1"

rc=$(run_case ghfail "$out")
ok "gh API failure exits 70" "$rc" "70"
ok "gh API failure is not pending" "$(grep -c '^RESULT=pending$' "$out")" "0"

bash scripts/codex_review_watch.sh --once --pr 123 --repo MartenH/blobly_net \
	--sha abcdef1234567890abcdef1234567890abcdef12 --interval 0 >"$out" 2>&1
ok "zero interval rejected" "$?" "64"

bash scripts/codex_review_watch.sh --once --pr 123 --repo MartenH/blobly_net \
	--sha abcdef1234567890abcdef1234567890abcdef12 --interval 1 >"$out" 2>&1
ok "direct watcher without freshness baseline is rejected" "$?" "64"

PATH="$stub:/usr/bin:/bin" bash scripts/codex_review_watch.sh --once --pr 123 --repo MartenH/blobly_net \
	--sha abcdef1234567890abcdef1234567890abcdef12 \
	--baseline-failure-comment-id 40 --interval 1 >"$out" 2>&1
ok "direct watcher with only failure baseline is rejected" "$?" "64"

PATH="$stub:/usr/bin:/bin" bash scripts/codex_review_watch.sh --once --pr 123 --repo MartenH/blobly_net \
	--sha abcdef1234567890abcdef1234567890abcdef12 \
	--baseline-review-id 0 \
	--baseline-pull-comment-id 0 \
	--baseline-issue-comment-id 0 \
	--baseline-failure-comment-id 0 \
	--interval 1 \
	--timeout 1 >"$out" 2>&1
ok "direct watcher with explicit baselines is allowed" "$?" "1"

PATH="$stub:/usr/bin:/bin" bash scripts/codex_review_watch.sh --once --pr 123 --repo MartenH/blobly_net \
	--sha abcdef1234567890abcdef1234567890abcdef12 \
	--baseline-review-id=0 \
	--baseline-pull-comment-id=0 \
	--baseline-issue-comment-id=0 \
	--baseline-failure-comment-id=0 \
	--interval 1 \
	--timeout 1 >"$out" 2>&1
ok "direct watcher accepts equals-style baselines" "$?" "1"

FAKE_GH_CASE=hang PATH="$stub:/usr/bin:/bin" bash scripts/codex_review_watch.sh --once --pr 123 --repo MartenH/blobly_net \
	--sha abcdef1234567890abcdef1234567890abcdef12 \
	--baseline-review-id 0 \
	--baseline-pull-comment-id 0 \
	--baseline-issue-comment-id 0 \
	--baseline-failure-comment-id 0 \
	--interval 1 \
	--timeout 1 >"$out" 2>&1
# A gh call that stalls past the deadline is an API failure, NOT an uneventful poll: the
# watcher never heard from GitHub. This fixture used to assert exit 1 -- it pinned the bug.
ok "a stalled gh API call exits 70, not pending" "$?" "70"
ok "a stalled gh API call says GitHub never answered" "$(grep -c 'stalled past the watch deadline' "$out")" "1"

PATH="$nogh:$stub:/usr/bin:/bin" bash scripts/codex_review_watch.sh --once --pr 123 --repo MartenH/blobly_net \
	--sha abcdef1234567890abcdef1234567890abcdef12 \
	--baseline-review-id 0 \
	--baseline-pull-comment-id 0 \
	--baseline-issue-comment-id 0 \
	--baseline-failure-comment-id 0 \
	--interval 1 \
	--timeout 1 >"$out" 2>&1
ok "watcher without gh exits API error" "$?" "70"
ok "watcher without gh has no traceback" "$(grep -c '^Traceback ' "$out")" "0"

bash scripts/request_codex_review.sh --help >"$out" 2>&1
ok "request helper handles help before PR" "$?" "0"
ok "request helper help prints usage" "$(grep -c '^usage:' "$out")" "1"

PATH="/usr/bin:/bin" bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net >"$out" 2>&1
ok "manual request mode works without gh" "$?" "0"
ok "manual request mode prints review comment" "$(grep -c '^@codex review$' "$out")" "1"

state_missing_ts=$(mktemp -d)
cat >"$state_missing_ts/pr-123.env" <<STATE
PR=123
REPO=MartenH/blobly_net
SHA=abcdef1234567890abcdef1234567890abcdef12
BASELINE_REVIEW_ID=10
BASELINE_PULL_COMMENT_ID=30
BASELINE_ISSUE_COMMENT_ID=999
BASELINE_FAILURE_COMMENT_ID=999
REQUEST_COMMENT_ID=999
REQUESTED_AT=
STATE
PATH="$stub:/usr/bin:/bin" bash scripts/codex_review_watch.sh --state "$state_missing_ts/pr-123.env" --once >"$out" 2>&1
ok "state with request id but no timestamp is recovered" "$?" "1"
ok "recovered watch state writes timestamp" "$(grep -c '^REQUESTED_AT=2026-01-01T00:00:02Z$' "$state_missing_ts/pr-123.env")" "1"

state_incomplete=$(mktemp -d)
cat >"$state_incomplete/pr-123.env" <<STATE
PR=123
REPO=MartenH/blobly_net
SHA=abcdef1234567890abcdef1234567890abcdef12
BASELINE_REVIEW_ID=10
REQUESTED_AT=
STATE
PATH="$stub:/usr/bin:/bin" bash scripts/codex_review_watch.sh --state "$state_incomplete/pr-123.env" --once >"$out" 2>&1
ok "incomplete state without request marker is rejected" "$?" "64"
ok "incomplete state rejection is explained" "$(grep -c 'state file is missing freshness fields' "$out")" "1"

repo_tmp=$(mktemp -d)
git -C "$repo_tmp" init -q
FAKE_GIT_ORIGIN=git@github.com:MartenH/blobly_net PATH="$stub:/usr/bin:/bin" \
	python3 scripts/codex_review.py watch --once --pr 123 \
	--sha abcdef1234567890abcdef1234567890abcdef12 \
	--baseline-review-id 0 --baseline-pull-comment-id 0 \
	--baseline-issue-comment-id 0 --baseline-failure-comment-id 0 \
	--interval 1 --timeout 1 >"$out" 2>&1
ok "SSH origin without suffix is inferred" "$?" "1"
FAKE_GIT_ORIGIN=ssh://git@github.com/MartenH/blobly_net.git PATH="$stub:/usr/bin:/bin" \
	python3 scripts/codex_review.py watch --once --pr 123 \
	--sha abcdef1234567890abcdef1234567890abcdef12 \
	--baseline-review-id 0 --baseline-pull-comment-id 0 \
	--baseline-issue-comment-id 0 --baseline-failure-comment-id 0 \
	--interval 1 --timeout 1 >"$out" 2>&1
ok "ssh:// origin with suffix is inferred" "$?" "1"

state_dir=$(mktemp -d)
cat >"$state_dir/pr-123.env" <<STATE
PR=123
REPO=MartenH/blobly_net
SHA=abcdef1234567890abcdef1234567890abcdef12
BASELINE_REVIEW_ID=10
BASELINE_PULL_COMMENT_ID=30
BASELINE_ISSUE_COMMENT_ID=40
BASELINE_FAILURE_COMMENT_ID=40
REQUESTED_AT=2026-01-01T00:00:01Z
STATE
FAKE_GH_CASE=manual_pending PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$state_dir" >"$out" 2>&1
ok "same-SHA pending request is rejected" "$?" "64"
ok "same-SHA pending request is explained" "$(grep -c 'same-SHA review is still pending' "$out")" "1"

dirty_state=$(mktemp -d)
FAKE_GIT_DIRTY=1 FAKE_GH_CASE=request_success PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$dirty_state" >"$out" 2>&1
ok "request helper rejects dirty worktree" "$?" "64"
ok "dirty worktree request is explained" "$(grep -c 'worktree has uncommitted or untracked files' "$out")" "1"

FAKE_GH_CASE=ghfail PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$state_dir" >"$out" 2>&1
ok "same-SHA indeterminate scan exits API error" "$?" "70"
ok "same-SHA indeterminate scan is explained" "$(grep -c 'could not determine whether the same-SHA review is still pending' "$out")" "1"

recovery_state=$(mktemp -d)
cat >"$recovery_state/pr-123.env" <<STATE
PR=123
REPO=MartenH/blobly_net
SHA=abcdef1234567890abcdef1234567890abcdef12
BASELINE_REVIEW_ID=10
BASELINE_PULL_COMMENT_ID=30
BASELINE_ISSUE_COMMENT_ID=999
BASELINE_FAILURE_COMMENT_ID=999
REQUEST_COMMENT_ID=999
REQUESTED_AT=
STATE
FAKE_GH_CASE=manual_pending PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$recovery_state" >"$out" 2>&1
ok "same-SHA request with missing timestamp is recovered before rejection" "$?" "64"
ok "recovered request state writes timestamp" "$(grep -c '^REQUESTED_AT=2026-01-01T00:00:02Z$' "$recovery_state/pr-123.env")" "1"

alt_state=$(mktemp -d)
cat >"$alt_state/pr-123.env" <<STATE
PR=123
REPO=MartenH/blobly_net
SHA=abcdef1234567890abcdef1234567890abcdef12
BASELINE_REVIEW_ID=10
BASELINE_PULL_COMMENT_ID=30
BASELINE_ISSUE_COMMENT_ID=40
BASELINE_FAILURE_COMMENT_ID=40
REQUESTED_AT=2026-01-01T00:00:01Z
STATE
CODEX_REVIEW_ACTOR=alt-bot FAKE_GH_CASE=alt_actor_clean PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$alt_state" >"$out" 2>&1
ok "same-SHA completed review from configured actor does not block request" "$?" "0"
ok "configured actor request is posted" "$(grep -c 'issuecomment-999' "$out")" "1"

remote_state=$(mktemp -d)
FAKE_GH_CASE=remote_pending PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$remote_state" >"$out" 2>&1
ok "remote same-SHA pending request is rejected" "$?" "64"
ok "remote same-SHA pending request is explained" "$(grep -c 'same-SHA review is already pending from request comment 998' "$out")" "1"

# ...and a dropped trigger must be recoverable: the marker lives in the PR, so removing the
# local state file cannot clear it, and without an override the PR wedges forever.
force_state=$(mktemp -d)
FAKE_GH_CASE=remote_pending PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --force --state-dir "$force_state" >"$out" 2>&1
ok "--force re-requests over a pending marker" "$?" "0"
ok "--force says it overrode the marker" "$(grep -c 'force: re-requesting over pending request comment 998' "$out")" "1"
ok "the pending guard names the override" "$(grep -c 'pass --force to request again' "$out")" "0"

# A persistent outage must not read as an ordinary pending review: retries consume the window,
# and the expiry that follows would otherwise report EXIT_PENDING for a watcher that never once
# reached GitHub.
cat >"$stub/gh_always_fail" <<'GHF'
#!/usr/bin/env bash
echo "simulated persistent 502" >&2
exit 1
GHF
chmod +x "$stub/gh_always_fail"
fail_dir=$(mktemp -d)
cp "$stub/git" "$fail_dir/git"
cp "$stub/gh_always_fail" "$fail_dir/gh"
PATH="$fail_dir:/usr/bin:/bin" \
	bash scripts/codex_review_watch.sh --pr 123 --repo MartenH/blobly_net \
	--sha abcdef1234567890abcdef1234567890abcdef12 \
	--baseline-review-id 10 --baseline-pull-comment-id 30 \
	--baseline-issue-comment-id 40 --baseline-failure-comment-id 40 \
	--requested-at 2026-01-01T00:00:01Z --interval 1 --timeout 3 >"$out" 2>&1
ok "a persistent API failure exits 70, not pending" "$?" "70"
ok "a persistent API failure says the window was consumed" "$(grep -c 'consumed the whole' "$out")" "1"

# A round is not handled until every finding has a reply. Only the bot's own findings count,
# and a reply on any page clears the one it points at.
FAKE_GH_CASE=unanswered PATH="$stub:/usr/bin:/bin" \
	bash scripts/codex_review_unanswered.sh 123 --repo MartenH/blobly_net >"$out" 2>&1
ok "unanswered exits 20 while a finding has no reply" "$?" "20"
ok "unanswered names the open finding" "$(grep -c '^UNANSWERED 32 b.v:2$' "$out")" "1"
ok "unanswered skips the replied-to finding" "$(grep -c '^UNANSWERED 31' "$out")" "0"
ok "unanswered ignores non-reviewer comments" "$(grep -c '^UNANSWERED 34' "$out")" "0"
ok "unanswered reports the tally" "$(grep -c '1 unanswered of 2 findings' "$out")" "1"

# --force must clear the RETAINED LOCAL STATE too, not only the marker in the PR: a dropped
# trigger leaves both behind, and the state check runs first.
saved_state=$(mktemp -d)
cat >"$saved_state/pr-123.env" <<'ENV'
PR=123
REPO=MartenH/blobly_net
SHA=abcdef1234567890abcdef1234567890abcdef12
BASELINE_REVIEW_ID=10
BASELINE_PULL_COMMENT_ID=30
BASELINE_ISSUE_COMMENT_ID=40
BASELINE_FAILURE_COMMENT_ID=40
REQUEST_COMMENT_ID=999
REQUESTED_AT=2026-01-01T00:00:01Z
ENV
cp "$saved_state/pr-123.env" "$saved_state/pr-123.env.bak"
FAKE_GH_CASE=request_success PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$saved_state" >"$out" 2>&1
ok "a saved pending state blocks a plain re-request" "$?" "64"
ok "the saved-state guard names the override" "$(grep -c 'pass --force to request again' "$out")" "1"

cp "$saved_state/pr-123.env.bak" "$saved_state/pr-123.env"
FAKE_GH_CASE=request_success PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --force --state-dir "$saved_state" >"$out" 2>&1
ok "--force re-requests over a saved pending state" "$?" "0"
ok "--force says it overrode the saved state" "$(grep -c 'force: re-requesting over the saved pending state' "$out")" "1"

spoof_state=$(mktemp -d)
FAKE_GH_CASE=remote_spoof PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$spoof_state" >"$out" 2>&1
ok "spoofed remote marker does not block request" "$?" "0"
ok "spoofed remote marker request is posted" "$(grep -c 'issuecomment-999' "$out")" "1"

stale_lock_state=$(mktemp -d)
stale_lock_parent=$(mktemp -d)
mkdir "$stale_lock_parent/codex-review-pr-123.lock"
cat >"$stale_lock_parent/codex-review-pr-123.lock/owner" <<STATE
pid=999999
created_at=1
STATE
CODEX_REVIEW_LOCK_DIR="$stale_lock_parent" CODEX_REVIEW_LOCK_STALE_SECONDS=0 \
	FAKE_GH_CASE=request_success PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$stale_lock_state" >"$out" 2>&1
ok "stale request lock is reclaimed" "$?" "0"
ok "stale request lock request is posted" "$(grep -c 'issuecomment-999' "$out")" "1"
ok "stale request lock is removed after request" "$([ -d "$stale_lock_parent/codex-review-pr-123.lock" ]; echo "$?")" "1"

live_lock_state=$(mktemp -d)
live_lock_parent=$(mktemp -d)
mkdir "$live_lock_parent/codex-review-pr-123.lock"
cat >"$live_lock_parent/codex-review-pr-123.lock/owner" <<STATE
pid=$$
created_at=1
token=live-owner
STATE
CODEX_REVIEW_LOCK_DIR="$live_lock_parent" CODEX_REVIEW_LOCK_STALE_SECONDS=0 CODEX_REVIEW_LOCK_TIMEOUT_SECONDS=1 \
	FAKE_GH_CASE=request_success PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$live_lock_state" >"$out" 2>&1
ok "live request lock is not reclaimed by age alone" "$?" "64"
ok "live request lock timeout is explained" "$(grep -c 'timed out waiting' "$out")" "1"
ok "live request lock remains" "$([ -d "$live_lock_parent/codex-review-pr-123.lock" ]; echo "$?")" "0"

other_repo_state=$(mktemp -d)
cat >"$other_repo_state/pr-123.env" <<STATE
PR=123
REPO=Other/Repo
SHA=abcdef1234567890abcdef1234567890abcdef12
BASELINE_REVIEW_ID=10
BASELINE_PULL_COMMENT_ID=30
BASELINE_ISSUE_COMMENT_ID=40
BASELINE_FAILURE_COMMENT_ID=40
REQUESTED_AT=2026-01-01T00:00:01Z
STATE
FAKE_GH_CASE=request_success PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$other_repo_state" >"$out" 2>&1
ok "old state for another repo does not retarget request" "$?" "0"
ok "new state preserves requested repo" "$(grep -c '^REPO=MartenH/blobly_net$' "$other_repo_state/pr-123.env")" "1"

mismatch_state=$(mktemp -d)
FAKE_GIT_HEAD_SHA=fedcba9876543210fedcba9876543210fedcba98 FAKE_GH_CASE=request_success PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$mismatch_state" >"$out" 2>&1
ok "request helper rejects PR head that differs from local HEAD" "$?" "64"
ok "request helper explains local/remote mismatch" "$(grep -c 'does not match PR head' "$out")" "1"

timestamp_fail_state=$(mktemp -d)
FAKE_GH_CASE=request_timestamp_fail PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$timestamp_fail_state" >"$out" 2>&1
ok "posted request with failed timestamp exits API error" "$?" "70"
ok "posted request state is persisted before timestamp lookup" "$(grep -c '^REQUEST_COMMENT_ID=999$' "$timestamp_fail_state/pr-123.env")" "1"

head_fail_state=$(mktemp -d)
FAKE_GH_CASE=request_head_fail PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$head_fail_state" >"$out" 2>&1
ok "request helper maps gh pr view failure to API error" "$?" "70"
ok "request helper API error has no traceback" "$(grep -c '^Traceback ' "$out")" "0"

echo "codex_review_watch: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
