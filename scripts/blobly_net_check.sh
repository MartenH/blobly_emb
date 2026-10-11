# Sourced, never run: require_blobly_net <dir> — refuse a BLOBLY_NET that is missing, or a
# blobly_net from before its engine moved to blobly/ (blobly_net#447), naming which, before a
# caller spends any time building. POSIX sh, for the bash and sh callers alike.
require_blobly_net() {
	[ -d "$1/blobly" ] && return 0
	if [ -d "$1/modules" ]; then
		echo "blobly_net at $1 predates net#447 (the engine moved to blobly/): update it" >&2
	else
		echo "no blobly_net at $1 (set BLOBLY_NET)" >&2
	fi
	return 1
}
