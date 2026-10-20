# net_env.sh — source it: system_full's addresses as sysgen resolved them (gen-net.env beside
# system.toml, the segment subnet or BLOB_NET_SUBNET applied), so a bench script talks to the
# addresses of the last generation (what a build since then flashed) instead of keeping its own
# copy. <NODE>_ADDR, and <NODE>_PORT for a SOME/IP member (a plain IP host such as OTA_GW has none).
# Exits 2 (SKIP) when the system has not been generated yet.
NET_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gen-net.env"
if [ ! -f "$NET_ENV" ]; then
  echo "SKIP: no $NET_ENV — run: make -C examples/system_full gen"
  exit 2
fi
. "$NET_ENV"
