#!/bin/bash
# Entrypoint of the redroid-webrtc image: runs the cuttlefish operator (web UI
# and signaling) and one redroid_webrtc streamer per device. All processes
# share this container's network namespace, which the operator requires (it
# reaches each streamer's client files at 127.0.0.1).
#
# Environment:
#   REDROID_DEVICES   comma separated list of devices, each "name=host:port"
#                     or just "host:port" (name defaults to the host),
#                     e.g. "redroid1=172.30.0.11:5555,redroid2=172.30.0.12:5555"
#   HTTPS_PORT        operator HTTPS port (default 8443, 0 disables)
#   HTTP_PORT         operator HTTP port (default 8080)
#   LISTEN_ADDR       operator listen address (default 0.0.0.0)
#   UDP_PORT_MIN/MAX  UDP port range for WebRTC media (default 15550-15599),
#                     shared by all streamers
#   STREAMER_ARGS     extra flags for every redroid_webrtc process
#   TLS_CERT_DIR      directory with cert.pem/key.pem (generated if missing)
set -euo pipefail

SHARE=/usr/share/redroid-webrtc
RUN_DIR=/run/redroid-webrtc
HTTPS_PORT="${HTTPS_PORT:-8443}"
HTTP_PORT="${HTTP_PORT:-8080}"
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
UDP_PORT_MIN="${UDP_PORT_MIN:-15550}"
UDP_PORT_MAX="${UDP_PORT_MAX:-15599}"
TLS_CERT_DIR="${TLS_CERT_DIR:-/var/lib/redroid-webrtc/cert}"
read -r -a EXTRA_ARGS <<< "${STREAMER_ARGS:-}"

if [ -z "${REDROID_DEVICES:-}" ]; then
  echo "REDROID_DEVICES is empty, e.g. REDROID_DEVICES=redroid1=172.30.0.11:5555" >&2
  exit 1
fi

if [ ! -d /dev/dma_heap ]; then
  echo "WARNING: /dev/dma_heap missing on this host. redroid needs a kernel with" >&2
  echo "CONFIG_DMABUF_HEAPS for video encoding; the stream may stay black." >&2
fi

mkdir -p "$RUN_DIR"
pids=()
cleanup() {
  trap - TERM INT
  kill -TERM "${pids[@]}" 2>/dev/null || true
  wait || true
}
trap cleanup TERM INT

# Operator
operator_args=(--socket_path="$RUN_DIR/operator"
               --control_socket_path="$RUN_DIR/operator_control"
               --listen_addr="$LISTEN_ADDR" --http_port="$HTTP_PORT")
if [ "$HTTPS_PORT" != "0" ]; then
  if [ ! -f "$TLS_CERT_DIR/cert.pem" ] || [ ! -f "$TLS_CERT_DIR/key.pem" ]; then
    echo "Generating a self-signed TLS certificate in $TLS_CERT_DIR"
    mkdir -p "$TLS_CERT_DIR"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=redroid-webrtc" \
      -keyout "$TLS_CERT_DIR/key.pem" -out "$TLS_CERT_DIR/cert.pem" 2>/dev/null
  fi
  operator_args+=(--https_port="$HTTPS_PORT" --tls_cert_dir="$TLS_CERT_DIR")
fi
(cd "$SHARE/operator" && exec operator "${operator_args[@]}") &
pids+=($!)

for _ in $(seq 50); do
  [ -S "$RUN_DIR/operator" ] && break
  sleep 0.1
done

adb start-server >/dev/null 2>&1 || true

# One supervised streamer per device.
run_streamer() {
  local name="$1" serial="$2" scrcpy_port="$3"
  while true; do
    redroid_webrtc --device_id="$name" --adb_serial="$serial" \
      --operator_path="$RUN_DIR/operator" --client_dir="$SHARE/html_client" \
      --scrcpy_server="$SHARE/scrcpy-server" --scrcpy_port="$scrcpy_port" \
      --udp_port_min="$UDP_PORT_MIN" --udp_port_max="$UDP_PORT_MAX" \
      ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} 2>&1 | sed -u "s/^/[$name] /" || true
    echo "[$name] streamer exited, restarting in 5s" >&2
    sleep 5
  done
}

scrcpy_port=27183
IFS=',' read -r -a devices <<< "$REDROID_DEVICES"
for device in "${devices[@]}"; do
  device="$(echo "$device" | xargs)"
  [ -z "$device" ] && continue
  if [[ "$device" == *=* ]]; then
    name="${device%%=*}"
    serial="${device#*=}"
  else
    serial="$device"
    name="${device%%:*}"
  fi
  [[ "$serial" == *:* ]] || serial="$serial:5555"
  echo "Device $name -> $serial"
  run_streamer "$name" "$serial" "$scrcpy_port" &
  pids+=($!)
  scrcpy_port=$((scrcpy_port + 1))
done

echo "Web UI: https://<host>:$HTTPS_PORT/ (or http://<host>:$HTTP_PORT/)"
# Exit (and let the container restart policy act) if the operator dies.
wait "${pids[0]}"
cleanup
