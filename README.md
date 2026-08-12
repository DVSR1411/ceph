# Rook Ceph — RGW-only, with Dashboard UI
## (vcluster / Docker driver — NBD disk passthrough)

## Prerequisites
- Docker host with at least **60 GiB free disk** (3 × 20 GiB sparse images)
- `vcluster` CLI, `helm 3`, `kubectl`, `qemu-utils` installed on the host
- `nbd` kernel module loaded:
  ```bash
  sudo modprobe nbd max_part=8
  # make it persist across reboots:
  echo "nbd" | sudo tee /etc/modules-load.d/nbd.conf
  ```

---

## Quick start (fresh machine)

```bash
bash deploy.sh
```

`deploy.sh` handles everything: sanity checks, disk image creation, vcluster
creation, NBD device setup, Rook operator + cluster install, CRUSH map fix,
dashboard LoadBalancer, `.env` generation for `app.py`, and health check.
It is idempotent — safe to re-run if something fails partway through.

---

## File reference

| File | Purpose |
|------|---------|
| `vcluster-docker-nodes.yaml` | vcluster config — passes `/dev/nbdX` into each worker container with `--privileged` |
| `setup-nbd-devices.sh` | Connects `.img` files to `/dev/nbd{0,1,2}` via `qemu-nbd` and injects device nodes into containers (called by `deploy.sh`) |
| `operator-values.yaml` | Rook operator Helm values — CSI drivers disabled (RGW-only), minimal resources |
| `cluster-values.yaml` | Ceph cluster Helm values — explicit node/device list, RGW store, dashboard |
| `object-store-user.yaml` | Creates an S3 user; credentials land in a Secret |
| `dashboard-loadbalancer.yaml` | LoadBalancer service for the Ceph dashboard (port 7000) |
| `deploy.sh` | **Full deploy script** — runs all steps in order |

---

## What the deploy script does (step by step)

### Step 0 — Sanity checks
Verifies all required binaries are on `$PATH`: `vcluster`, `helm`, `kubectl`, `docker`, `qemu-nbd`.
Also confirms the `nbd` kernel module is loaded — exits immediately if not.

### Step 1 — Disk images
Creates three 20 GiB sparse files under `/var/lib/rook-loop-disks/` (skipped if they already exist):
```
/var/lib/rook-loop-disks/worker-{1,2,3}.img
```
Thin-provisioned via `truncate` — only consume real space as data is written.
Total raw capacity: 60 GiB → ~40 GiB usable (replication size 2).

### Step 2 — vcluster
If a vcluster named `test` already exists, reconnects to it (`vcluster connect test`).
Otherwise creates it fresh:
```bash
vcluster create test -f vcluster-docker-nodes.yaml
```
Creates 3 worker node containers. Each gets `--privileged` and `--device=/dev/nbdX`
so the NBD block device is visible inside.

### Step 3 — NBD devices
```bash
sudo bash setup-nbd-devices.sh
```
Runs `qemu-nbd --connect=/dev/nbdX -f raw <image>` for each worker and injects
the device nodes into the containers via `docker exec mknod`.
NBD devices appear as `TYPE=disk` to `lsblk` — this is what makes Rook accept
them (it rejects loop and dm devices by default).

After `setup-nbd-devices.sh` returns, the script verifies each device by reading
`/sys/block/nbdX/size` and exits with an error if any device reports size 0.

> **After a host reboot:** the `.img` files survive but NBD connections don't.
> Re-run `sudo bash setup-nbd-devices.sh` before anything else.

### Step 4 — Rook operator
Adds/updates the `rook-release` Helm repo, creates the `rook-ceph` namespace,
then installs the operator (skipped if already installed):
```bash
helm install rook-ceph rook-release/rook-ceph \
  --namespace rook-ceph -f operator-values.yaml
```
RBD and CephFS CSI drivers are disabled — we only need RGW.
Waits for `rook-ceph-operator` deployment rollout before continuing.

### Step 5 — Ceph cluster
Installs the cluster chart (skipped if already installed):
```bash
helm install rook-ceph-cluster rook-release/rook-ceph-cluster \
  --namespace rook-ceph -f cluster-values.yaml
```
Brings up: 3 mons, 1 mgr, 3 OSDs (one per NBD device), 1 RGW gateway, and the mgr dashboard module.

Waits for all mon pods to be `Ready` (up to 5 min), then polls until 3 OSD pods
are `Running` (up to 5 min), exiting with an error if they don't come up in time.

**Storage layout in `cluster-values.yaml`:**
- `useAllNodes/useAllDevices: false` + explicit node list — only the named devices become OSDs
- `metadataPool`: replicated `size: 2`
- `dataPool`: replicated `size: 2` (not erasure-coded — EC needs more OSDs than the 3 we have to avoid `pg undersized` warnings)

### Step 6 — CRUSH map fix + toolbox
In vcluster's Docker driver all node containers share the host kernel, so
Ceph's auto-discovery puts all 3 OSDs under the same host bucket (`worker-1`).
With `failureDomain: host` this means replicas can't spread and PGs stay `undersized`.

The script deploys the Rook toolbox and waits for it to be ready, then checks
whether `worker-2` already exists in the CRUSH tree. If not, it spreads the OSDs:
```bash
ceph osd crush add-bucket worker-2 host
ceph osd crush add-bucket worker-3 host
ceph osd crush move worker-2 root=default
ceph osd crush move worker-3 root=default
ceph osd crush move osd.1 host=worker-2
ceph osd crush move osd.2 host=worker-3
```
Also sets `.mgr` pool `min_size 1` so the mgr pool can go active with 3 OSDs.

After this the cluster reaches `HEALTH_OK`.

### Step 7 — Dashboard LoadBalancer
```bash
kubectl apply -f dashboard-loadbalancer.yaml
```
Exposes the dashboard on port `7000` via vcluster's built-in LoadBalancer support.
Polls until the service has an external IP assigned (up to 3 min).

> **RGW is not exposed via LoadBalancer.** vcluster's VIP-mode LB IPs are only reachable within the Docker bridge network, not from the host. Access RGW from the host via port-forward instead (see below).

### Step 7b — Write `.env`
Reads the S3 credentials from the `rook-ceph-object-user-rgw-store-s3-user` secret
and writes `.env` for `app.py`:
```
CEPH_RGW_HOST=localhost
RGW_ACCESS_KEY=<from secret>
RGW_SECRET_KEY=<from secret>
RGW_REGION=us-east-1
RGW_PORT=7480
CEPH_BUCKET=test
```
Note: the S3 user secret is only present if `object-store-user.yaml` has been applied.
If the secret doesn't exist yet, `ACCESS_KEY`/`SECRET_KEY` will be empty — apply
the user manifest and re-run the script, or fill in `.env` manually.

### Step 8 — Health check
Polls `cephcluster.status.ceph.health` every 10 s for up to 3 min until `HEALTH_OK`.
Prints the current health status on each iteration so you can see progress.

---

## Accessing the cluster

### Dashboard
```
https://<dashboard-lb-ip>:7000  (user: admin)
```
Get the password:
```bash
kubectl -n rook-ceph get secret rook-ceph-dashboard-password \
  -o jsonpath="{['data']['password']}" | base64 -d; echo
```
Get the IP:
```bash
kubectl -n rook-ceph get svc rook-ceph-dashboard-lb
```

> The dashboard shows Prometheus warnings — expected, monitoring is disabled.

### RGW S3 endpoint
RGW is accessed from the host via `kubectl port-forward` (vcluster LB VIPs are not routable from the host):
```bash
kubectl -n rook-ceph port-forward svc/rook-ceph-rgw-rgw-store 7480:80
```
Endpoint: `http://localhost:7480`

### Create S3 credentials
```bash
kubectl apply -f object-store-user.yaml

kubectl -n rook-ceph get secret rook-ceph-object-user-rgw-store-s3-user \
  -o jsonpath='{.data.AccessKey}' | base64 -d; echo
kubectl -n rook-ceph get secret rook-ceph-object-user-rgw-store-s3-user \
  -o jsonpath='{.data.SecretKey}' | base64 -d; echo
```

### Test S3
```bash
# In a separate terminal:
kubectl -n rook-ceph port-forward svc/rook-ceph-rgw-rgw-store 7480:80

aws --endpoint-url http://localhost:7480 s3 mb s3://test-bucket
aws --endpoint-url http://localhost:7480 s3 ls
```

---

## Teardown

```bash
helm uninstall rook-ceph-cluster -n rook-ceph
helm uninstall rook-ceph -n rook-ceph

# Strip finalizers so the namespace actually deletes
kubectl -n rook-ceph patch cephcluster rook-ceph \
  --type=merge -p '{"metadata":{"finalizers":[]}}'
kubectl -n rook-ceph patch cephobjectstore rgw-store \
  --type=merge -p '{"metadata":{"finalizers":[]}}'
kubectl -n rook-ceph patch clientprofile rook-ceph \
  --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
kubectl get namespace rook-ceph -o json \
  | python3 -c "import json,sys; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; print(json.dumps(ns))" \
  | kubectl replace --raw /api/v1/namespaces/rook-ceph/finalize -f -

vcluster delete test

# Disconnect NBD devices
sudo qemu-nbd --disconnect /dev/nbd0
sudo qemu-nbd --disconnect /dev/nbd1
sudo qemu-nbd --disconnect /dev/nbd2
```

To also wipe the disk images (full reset):
```bash
sudo rm /var/lib/rook-loop-disks/worker-*.img
```

---

## Known gotchas

| Issue | Cause | Fix |
|-------|-------|-----|
| OSD prepare jobs skip devices with "different ceph cluster" | Stale Ceph metadata on disk from a previous run | Delete and recreate the `.img` files, reconnect NBD |
| All OSDs land on `worker-1` in CRUSH map | vind containers share host kernel — Ceph sees same hostname | Step 6 CRUSH fix in `deploy.sh` |
| `pg undersized` / `HEALTH_WARN` after install | EC data pool created before CRUSH fix, or `size > OSD count` | `cluster-values.yaml` uses replicated `size: 2`; CRUSH fix spreads OSDs |
| `qemu-nbd: Failed to set NBD socket` | Device already connected | Safe to ignore — check `cat /sys/block/nbdX/size` to confirm |
| Namespace stuck `Terminating` | Rook finalizers on CephCluster / CephObjectStore / clientprofile | See teardown section above |
| NBD devices gone after reboot | qemu-nbd connections don't persist | Re-run `sudo bash setup-nbd-devices.sh` |
| Prometheus warnings in dashboard | Monitoring stack not deployed | Expected — ignore them |
