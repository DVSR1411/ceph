#!/usr/bin/env bash
# Full Rook-Ceph RGW-only deployment on vcluster (docker/vind driver).
# Run as normal user: bash deploy.sh (sudo is used only where root is needed)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Ensure kubectl/helm/vcluster use the invoking user's kubeconfig even if called via sudo
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
# If run under sudo, fall back to the original user's home
if [ -n "${SUDO_USER:-}" ]; then
  export KUBECONFIG="/home/${SUDO_USER}/.kube/config"
fi

# ---------------------------------------------------------------------------
# 0. Sanity checks
# ---------------------------------------------------------------------------
echo "==> [0/8] Sanity checks..."
for cmd in vcluster helm kubectl docker qemu-nbd wipefs; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
done

if ! lsmod | grep -q nbd && [ ! -e /dev/nbd0 ]; then
  echo "ERROR: nbd kernel module not loaded. Run: sudo modprobe nbd max_part=8"
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Create backing disk images (skipped if they already exist)
# ---------------------------------------------------------------------------
echo "==> [1/8] Preparing disk images..."
DIR="/var/lib/rook-loop-disks"
sudo mkdir -p "$DIR"
for NODE in worker-1 worker-2 worker-3; do
  FILE="$DIR/${NODE}.img"
  # Always recreate — reusing old images risks stale bluestore metadata
  echo "    Creating $FILE (20G sparse)..."
  sudo rm -f "$FILE"
  sudo truncate -s 20G "$FILE"
done

# ---------------------------------------------------------------------------
# 2. Start vcluster
# ---------------------------------------------------------------------------
echo "==> [2/8] Starting vcluster 'test'..."
if vcluster list 2>/dev/null | grep -q "test"; then
  echo "    vcluster 'test' already exists, connecting..."
  vcluster connect test
else
  vcluster create test -f vcluster-docker-nodes.yaml
fi

# Give node containers a moment to fully start
sleep 5

# ---------------------------------------------------------------------------
# 3. Connect NBD devices, wipe, inject into node containers
# ---------------------------------------------------------------------------
echo "==> [3/8] Connecting NBD devices..."

# Disconnect any stale connections first
for i in 0 1 2; do
  sudo qemu-nbd --disconnect /dev/nbd$i 2>/dev/null || true
done
sleep 2

# Connect each image to its NBD device
sudo qemu-nbd --connect=/dev/nbd0 --format=raw "$DIR/worker-1.img"
sudo qemu-nbd --connect=/dev/nbd1 --format=raw "$DIR/worker-2.img"
sudo qemu-nbd --connect=/dev/nbd2 --format=raw "$DIR/worker-3.img"
sleep 3

# Verify all devices are connected and non-zero
for i in 0 1 2; do
  size=$(cat /sys/block/nbd${i}/size 2>/dev/null || echo 0)
  [ "$size" -gt 0 ] || { echo "ERROR: /dev/nbd${i} not connected or zero size"; exit 1; }
done
echo "    nbd0/1/2 all connected."

# Wipe stale bluestore/filesystem metadata from previous runs
# wipefs removes partition/fs signatures; dd zeros the bluestore superblock
echo "    Wiping stale metadata from nbd devices..."
for i in 0 1 2; do
  sudo wipefs -a /dev/nbd${i}
  sudo dd if=/dev/zero of=/dev/nbd${i} bs=1M count=200 status=none
done
echo "    Wipe done."

# Inject correct device node into each container and remove all others (nbd0-15)
declare -A NODE_DEV=([worker-1]=0 [worker-2]=1 [worker-3]=2)
for NODE in worker-1 worker-2 worker-3; do
  CTR="vcluster.node.test.${NODE}"
  OWN="${NODE_DEV[$NODE]}"

  MAJ=$(printf '%d' "0x$(stat -c '%t' /dev/nbd${OWN})")
  MIN=$(printf '%d' "0x$(stat -c '%T' /dev/nbd${OWN})")
  docker exec --privileged "$CTR" mknod -m 0660 /dev/nbd${OWN} b "$MAJ" "$MIN" 2>/dev/null || true

  for OTHER in $(seq 0 15); do
    [ "$OTHER" -eq "$OWN" ] && continue
    docker exec --privileged "$CTR" rm -f /dev/nbd${OTHER} 2>/dev/null || true
  done

  echo "    $NODE -> /dev/nbd${OWN} injected, nbd0-15 others removed."
done

# ---------------------------------------------------------------------------
# 4. Install Rook operator
# ---------------------------------------------------------------------------
echo "==> [4/8] Installing Rook operator..."
helm repo add rook-release https://charts.rook.io/release 2>/dev/null || true
helm repo update rook-release

kubectl create namespace rook-ceph 2>/dev/null || true

if helm status rook-ceph -n rook-ceph &>/dev/null; then
  echo "    Rook operator already installed, skipping."
else
  helm install rook-ceph rook-release/rook-ceph \
    --namespace rook-ceph \
    -f operator-values.yaml
fi

echo "    Waiting for operator rollout..."
kubectl -n rook-ceph rollout status deploy/rook-ceph-operator --timeout=180s

# ---------------------------------------------------------------------------
# 5. Install Ceph cluster
# ---------------------------------------------------------------------------
echo "==> [5/8] Installing Ceph cluster..."
if helm status rook-ceph-cluster -n rook-ceph &>/dev/null; then
  echo "    Ceph cluster already installed, skipping."
else
  helm install rook-ceph-cluster rook-release/rook-ceph-cluster \
    --namespace rook-ceph \
    -f cluster-values.yaml
fi

echo "    Waiting for mons (up to 5 min)..."
kubectl -n rook-ceph wait --for=condition=ready pod -l app=rook-ceph-mon --timeout=300s

# Wait for OSD prepare jobs to appear (up to 3 min)
echo "    Waiting for OSD prepare jobs to start..."
for i in $(seq 1 18); do
  job_count=$(kubectl -n rook-ceph get jobs --no-headers 2>/dev/null | grep -c "osd-prepare" || true)
  [ "$job_count" -ge 3 ] && break
  echo "    OSD prepare jobs found: $job_count/3 — waiting..."
  sleep 10
done

# Wait for OSD prepare jobs to complete (up to 5 min)
echo "    Waiting for OSD prepare jobs to complete..."
for i in $(seq 1 30); do
  done_count=$(kubectl -n rook-ceph get jobs --no-headers 2>/dev/null | grep "osd-prepare" | grep -c "1/1" || true)
  [ "$done_count" -ge 3 ] && break
  echo "    OSD prepare jobs done: $done_count/3 — waiting..."
  sleep 10
done

# Wait for OSD pods to be Running (up to 5 min)
echo "    Waiting for OSD pods (up to 5 min)..."
osd_count=0
for i in $(seq 1 30); do
  osd_count=$(kubectl -n rook-ceph get pods -l app=rook-ceph-osd --no-headers 2>/dev/null | grep -c "Running" || true)
  [ "$osd_count" -ge 3 ] && break
  echo "    OSDs running: $osd_count/3 — waiting..."
  sleep 10
done
[ "$osd_count" -ge 3 ] || { echo "ERROR: OSDs did not come up in time"; exit 1; }

# ---------------------------------------------------------------------------
# 6. Fix CRUSH map + toolbox
# ---------------------------------------------------------------------------
echo "==> [6/8] Fixing CRUSH map..."
kubectl apply -f https://raw.githubusercontent.com/rook/rook/master/deploy/examples/toolbox.yaml
kubectl -n rook-ceph rollout status deploy/rook-ceph-tools --timeout=120s

worker2_exists=$(kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph osd tree 2>/dev/null | grep -c "worker-2" || true)

if [ "$worker2_exists" -eq 0 ]; then
  echo "    Spreading OSDs across host buckets..."
  kubectl -n rook-ceph exec deploy/rook-ceph-tools -- bash -c '
    ceph osd crush add-bucket worker-2 host
    ceph osd crush add-bucket worker-3 host
    ceph osd crush move worker-2 root=default
    ceph osd crush move worker-3 root=default
    # Dynamically find OSD IDs that are not osd.0 (which stays on worker-1)
    OSDS=$(ceph osd tree --format json | python3 -c "
import json,sys
t=json.load(sys.stdin)
ids=[str(n[\"id\"]) for n in t[\"nodes\"] if n.get(\"type\")==\"osd\" and n[\"id\"]!=0]
print(\" \".join(ids))
")
    i=2
    for osd in $OSDS; do
      ceph osd crush move osd.${osd} host=worker-${i}
      i=$((i+1))
    done
  '
else
  echo "    CRUSH map already correct, skipping."
fi

# Set min_size 1 on all pools so they stay active with 3 OSDs at replication size 2
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- bash -c '
  for pool in $(ceph osd pool ls); do
    ceph osd pool set $pool min_size 1 2>/dev/null || true
  done
'

# ---------------------------------------------------------------------------
# 7. Apply LoadBalancer + wait for IP
# ---------------------------------------------------------------------------
echo "==> [7/8] Applying LoadBalancer services..."
kubectl apply -f dashboard-loadbalancer.yaml

echo "    Waiting for external IP (up to 3 min)..."
dash_ip=""
for i in $(seq 1 18); do
  dash_ip=$(kubectl -n rook-ceph get svc rook-ceph-dashboard-lb \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [ -n "$dash_ip" ] && break
  sleep 10
done

# ---------------------------------------------------------------------------
# 7b. Write .env for app.py
# ---------------------------------------------------------------------------
echo "==> Writing .env..."
ACCESS_KEY=$(kubectl -n rook-ceph get secret rook-ceph-object-user-rgw-store-s3-user \
  -o jsonpath='{.data.AccessKey}' 2>/dev/null | base64 -d || true)
SECRET_KEY=$(kubectl -n rook-ceph get secret rook-ceph-object-user-rgw-store-s3-user \
  -o jsonpath='{.data.SecretKey}' 2>/dev/null | base64 -d || true)

cat > .env <<EOF
CEPH_RGW_HOST=localhost
RGW_ACCESS_KEY=${ACCESS_KEY}
RGW_SECRET_KEY=${SECRET_KEY}
RGW_REGION=us-east-1
RGW_PORT=7480
CEPH_BUCKET=test
EOF
echo "    .env written."

# ---------------------------------------------------------------------------
# 8. Wait for HEALTH_OK
# ---------------------------------------------------------------------------
echo "==> [8/8] Waiting for HEALTH_OK (up to 5 min)..."
health="unknown"
for i in $(seq 1 30); do
  health=$(kubectl -n rook-ceph get cephcluster rook-ceph \
    -o jsonpath='{.status.ceph.health}' 2>/dev/null || echo "unknown")
  echo "    Health: $health"
  [ "$health" = "HEALTH_OK" ] && break
  sleep 10
done

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
dash_ip=$(kubectl -n rook-ceph get svc rook-ceph-dashboard-lb \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "<pending>")

echo ""
echo "======================================================"
echo " Ceph cluster is up!"
echo "======================================================"
echo ""
echo "Dashboard: https://${dash_ip}:7000  (user: admin)"
echo "Password:"
kubectl -n rook-ceph get secret rook-ceph-dashboard-password \
  -o jsonpath="{['data']['password']}" | base64 -d; echo
echo ""
echo "RGW S3 endpoint: http://localhost:7480  (via port-forward)"
echo "  Run: kubectl -n rook-ceph port-forward svc/rook-ceph-rgw-rgw-store 7480:80"
echo ""
echo "Create S3 user:  kubectl apply -f object-store-user.yaml"
