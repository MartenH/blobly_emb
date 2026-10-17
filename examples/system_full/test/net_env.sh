# net_env.sh — source it: system_full's addresses as sysgen resolved them (gen-net.env beside
# system.toml, the segment subnet or BLOB_NET_SUBNET applied), so a bench script talks to the
# address the images were built with instead of keeping its own copy. <NODE>_ADDR / <NODE>_PORT.
# Exits 2 (SKIP) when the system has not been generated yet.
NET_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gen-net.env"
if [ ! -f "$NET_ENV" ]; then
  echo "SKIP: no $NET_ENV — run: make -C examples/system_full gen"
  exit 2
fi
. "$NET_ENV"
