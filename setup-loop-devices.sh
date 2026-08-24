#!/usr/bin/env bash
# Connects each worker's backing image to a loop device inside the kind node container.
# Run after `kind create cluster` — re-run after host reboot.
set -euo pipefail

DIR="/var/lib/rook-loop-disks"

declare -A NODES=(
  [kind-worker]="worker-1"
  [kind-worker2]="worker-2"
  [kind-worker3]="worker-3"
)

for CTR in kind-worker kind-worker2 kind-worker3; do
  IMG_NAME="${NODES[$CTR]}"
  IMG="/mnt/${IMG_NAME}.img"

  echo "Setting up loop device in $CTR for $IMG ..."

  # Find a free loop device inside the container
  LOOP=$(docker exec --privileged "$CTR" losetup -f)

  docker exec --privileged "$CTR" losetup "$LOOP" "$IMG"
  docker exec --privileged "$CTR" bash -c "echo 1 > /sys/block/$(basename $LOOP)/ro" 2>/dev/null || true

  SIZE=$(docker exec "$CTR" blockdev --getsize64 "$LOOP" 2>/dev/null || echo 0)
  echo "  $CTR -> $LOOP ($(( SIZE / 1024 / 1024 / 1024 )) GiB)"
done

echo ""
echo "Verify: docker exec kind-worker lsblk"
