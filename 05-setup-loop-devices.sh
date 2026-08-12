#!/usr/bin/env bash
# Run this on the Docker HOST machine (not inside a container), as root/sudo.
# Creates one sparse-file-backed loop device per node, to be used as a raw
# block device for Ceph OSDs.
#
# NOTE: this is a dev/testing pattern, not a production storage setup.
# Loop devices are slower than real disks and the sparse files still consume
# your host's real disk space as data is written to them (thin-provisioned) -
# so make sure the host actually has the free space you're allocating below.

set -euo pipefail

SIZE="20G"                       # size of each OSD's backing disk - adjust to what you can spare
                                  # NOTE: all 3 files live on the SAME host disk (one machine
                                  # running the docker containers), so this is 3x SIZE total
                                  # consumed from your real disk as data is written, not per-disk.
                                  # 20G x 3 nodes = 60G raw total (~30G usable with replication size:2).
DIR="/var/lib/rook-loop-disks"   # where the backing files live on the host
mkdir -p "$DIR"

for NODE in worker-1 worker-2 worker-3; do
  FILE="$DIR/${NODE}.img"
  if [ ! -f "$FILE" ]; then
    echo "Creating sparse file for $NODE ($SIZE) ..."
    truncate -s "$SIZE" "$FILE"
  fi

  LOOPDEV=$(losetup -f --show "$FILE")
  echo "$NODE -> $LOOPDEV (backed by $FILE)"
done

echo ""
echo "Loop devices created. Run 'losetup -a' to confirm."
echo "NOTE: loop devices don't survive a host reboot by default - you'll"
echo "need to re-run 'losetup -f --show <file>' after a reboot and update"
echo "the device name in 02-cluster-values.yaml if it changes."
