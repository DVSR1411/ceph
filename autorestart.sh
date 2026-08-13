#!/usr/bin/env bash
# One-time setup: makes vcluster + NBD devices survive system reboots.
# Run once after a successful deploy: bash autorestart.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set Docker restart policy on all vcluster containers
echo "==> Setting Docker restart policy..."
for CTR in vcluster.cp.test vcluster.node.test.worker-1 vcluster.node.test.worker-2 vcluster.node.test.worker-3; do
  docker update --restart=unless-stopped "$CTR"
  echo "    $CTR -> restart=unless-stopped"
done

# Install and enable the NBD reconnect systemd service
echo "==> Installing rook-nbd-reconnect.service..."
sudo cp "$SCRIPT_DIR/rook-nbd-reconnect.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable rook-nbd-reconnect.service

echo ""
echo "Done. After next reboot:"
echo "  - vcluster containers will auto-start via Docker"
echo "  - NBD devices will reconnect via rook-nbd-reconnect.service"
echo "  - OSDs will recover automatically (~2-3 min after boot)"
