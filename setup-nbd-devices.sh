#!/usr/bin/env bash
# Run as root on the Docker host.
# Connects each worker's backing image to an NBD device (TYPE=disk),
# injects the device node into the vcluster node container.
set -euo pipefail

declare -A NODES=(
  [worker-1]=/dev/nbd0
  [worker-2]=/dev/nbd1
  [worker-3]=/dev/nbd2
)

DIR="/var/lib/rook-loop-disks"

# Disconnect any existing NBD connections first
for DEV in /dev/nbd0 /dev/nbd1 /dev/nbd2; do
  qemu-nbd --disconnect "$DEV" 2>/dev/null || true
done

sleep 1

for NODE in worker-1 worker-2 worker-3; do
  NBD="${NODES[$NODE]}"
  IMG="$DIR/${NODE}.img"
  CTR="vcluster.node.test.${NODE}"

  echo "Connecting $IMG -> $NBD ..."
  qemu-nbd --connect="$NBD" -f raw "$IMG"

  # Wait for device to be ready
  sleep 1

  # Get major:minor
  MAJ=$(stat -c '%t' "$NBD")
  MIN=$(stat -c '%T' "$NBD")
  MAJ_DEC=$((16#$MAJ))
  MIN_DEC=$((16#$MIN))

  echo "Injecting $NBD ($MAJ_DEC:$MIN_DEC) into $CTR ..."
  docker exec --privileged "$CTR" mknod -m 0660 "$NBD" b "$MAJ_DEC" "$MIN_DEC" 2>/dev/null || true

  echo "$NODE -> $NBD ($(lsblk $NBD --nodeps --noheadings --output TYPE,SIZE))"
done

echo ""
echo "Verify: lsblk /dev/nbd0 /dev/nbd1 /dev/nbd2"
