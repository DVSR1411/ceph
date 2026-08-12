#!/usr/bin/env bash
# Full Rook-Ceph RGW-only deployment on vcluster (docker/vind driver).
# Run from the directory containing the values files.
# Prerequisites: vcluster CLI, helm, kubectl, qemu-utils, docker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# 0. Sanity checks
# ---------------------------------------------------------------------------
for cmd in vcluster helm kubectl docker qemu-nbd; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
done

lsmod | grep -q "^nbd" || { echo "ERROR: nbd kernel module not loaded. Run: sudo modprobe nbd max_part=8"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Create backing disk images (skipped if they already exist)
# ---------------------------------------------------------------------------
echo "==> [1/8] Preparing disk images..."
DIR="/var/lib/rook-loop-disks"
sudo mkdir -p "$DIR"
for NODE in worker-1 worker-2 worker-3; do
  FILE="$DIR/${NODE}.img"
  if [ ! -f "$FILE" ]; then
    echo "    Creating $FILE (20G sparse)..."
    sudo truncate -s 20G "$FILE"
  else
    echo "    $FILE already exists, skipping."
  fi
done

# ---------------------------------------------------------------------------
# 2. Start vcluster
# ---------------------------------------------------------------------------
echo "==> [2/8] Starting vcluster 'test'..."
if vcluster list 2>/dev/null | grep -q "^  test "; then
  echo "    vcluster 'test' already exists, connecting..."
  vcluster connect test
else
  vcluster create test -f vcluster-docker-nodes.yaml
fi

# ---------------------------------------------------------------------------
# 3. Connect NBD devices + inject into node containers
# ---------------------------------------------------------------------------
echo "==> [3/8] Connecting NBD devices (requires sudo)..."
sudo bash setup-nbd-devices.sh

echo "    Verifying devices..."
for dev in /dev/nbd0 /dev/nbd1 /dev/nbd2; do
  size=$(cat /sys/block/${dev##*/}/size 2>/dev/null || echo 0)
  [ "$size" -gt 0 ] || { echo "ERROR: $dev not connected"; exit 1; }
done
echo "    nbd0/1/2 all connected."

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

echo "    Waiting for operator..."
kubectl -n rook-ceph rollout status deploy/rook-ceph-operator --timeout=120s

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

echo "    Waiting for OSDs (up to 5 min)..."
for i in $(seq 1 30); do
  osd_count=$(kubectl -n rook-ceph get pods -l app=rook-ceph-osd --no-headers 2>/dev/null | grep -c "Running" || true)
  [ "$osd_count" -ge 3 ] && break
  echo "    OSDs running: $osd_count/3 — waiting..."
  sleep 10
done
[ "$osd_count" -ge 3 ] || { echo "ERROR: OSDs did not come up in time"; exit 1; }

# ---------------------------------------------------------------------------
# 6. Fix CRUSH map (all OSDs land on worker-1 by default in vind)
# ---------------------------------------------------------------------------
echo "==> [6/8] Fixing CRUSH map..."
kubectl apply -f https://raw.githubusercontent.com/rook/rook/master/deploy/examples/toolbox.yaml
kubectl -n rook-ceph rollout status deploy/rook-ceph-tools --timeout=120s

worker2_osds=$(kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph osd tree 2>/dev/null | grep -c "worker-2" || true)

if [ "$worker2_osds" -eq 0 ]; then
  echo "    Spreading OSDs across host buckets..."
  kubectl -n rook-ceph exec deploy/rook-ceph-tools -- bash -c "
    ceph osd crush add-bucket worker-2 host
    ceph osd crush add-bucket worker-3 host
    ceph osd crush move worker-2 root=default
    ceph osd crush move worker-3 root=default
    ceph osd crush move osd.1 host=worker-2
    ceph osd crush move osd.2 host=worker-3
  "
else
  echo "    CRUSH map already correct, skipping."
fi

# Fix .mgr pool min_size so it can go active with 3 OSDs
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd pool set .mgr min_size 1 2>/dev/null || true

# Uncomment to suppress Prometheus warnings in the dashboard (no Prometheus deployed)
# kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph mgr module disable prometheus 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7. Apply LoadBalancer services
# ---------------------------------------------------------------------------
echo "==> [7/8] Applying LoadBalancer services..."
kubectl apply -f dashboard-loadbalancer.yaml

echo "    Waiting for external IP..."
for i in $(seq 1 18); do
  dash_ip=$(kubectl -n rook-ceph get svc rook-ceph-dashboard-lb \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [ -n "$dash_ip" ] && break
  sleep 10
done

# ---------------------------------------------------------------------------
# 7b. Update .env for app.py
# ---------------------------------------------------------------------------
echo "==> Updating .env..."
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
echo "    NOTE: Run this in a separate terminal before starting app.py:"
echo "    kubectl -n rook-ceph port-forward svc/rook-ceph-rgw-rgw-store 7480:80"

# ---------------------------------------------------------------------------
# 8. Wait for HEALTH_OK
# ---------------------------------------------------------------------------
echo "==> [8/8] Waiting for HEALTH_OK (up to 3 min)..."
for i in $(seq 1 18); do
  health=$(kubectl -n rook-ceph get cephcluster rook-ceph \
    -o jsonpath='{.status.ceph.health}' 2>/dev/null || echo "unknown")
  echo "    Health: $health"
  [ "$health" = "HEALTH_OK" ] && break
  sleep 10
done

# ---------------------------------------------------------------------------
# Done — print access info
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
