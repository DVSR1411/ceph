# Rook Ceph — RGW-only, with Dashboard UI

## Prerequisites
- A k8s cluster with at least 3 nodes that each have a **raw, unformatted
  block device** attached (or a StorageClass that can dynamically provision
  block volumes, if using the PVC option).
- Helm 3 installed locally.
- `kubectl` pointed at your cluster.

Check available raw disks per node before writing the values file:
```bash
kubectl get nodes -o wide
# then, on each node (e.g. via `kubectl debug node/<node> -it --image=busybox`)
lsblk
```
Any disk that shows **no partitions / no filesystem** is a candidate for Ceph.

### Special case: running inside vCluster's Docker driver (vind)
If your 3 nodes are actually Docker containers created by vCluster's
`experimental.docker` mode, there's no real disk attached to them by
default — a bind-mounted directory (`volumes:`) is a filesystem, not a
block device, and Ceph's OSDs (BlueStore) require raw block, not a
directory. Do this first, on the Docker **host** machine:

1. Run `05-setup-loop-devices.sh` (as root) to create sparse-file-backed
   loop devices — one per node.
2. Run `losetup -a` to see which `/dev/loopX` got assigned to each file.
3. Update `06-vcluster-docker-nodes.yaml` with the real loop device names,
   and apply it as part of your vcluster config (adds `--privileged` +
   `--device` passthrough to each node container).
4. Recreate/update your vcluster so the node containers pick up the new
   device passthrough.
5. Update `02-cluster-values.yaml`'s `storage.nodes[].devices[].name`
   with the same loop device names.

This is a **dev/testing pattern only** — loop devices are slower than
real disks, don't survive a host reboot without re-running `losetup`,
and the backing sparse files still consume real space on the host disk
as data is written. Don't use this for anything you care about keeping.

---

## Step 1 — Add the Rook Helm repo
```bash
helm repo add rook-release https://charts.rook.io/release
helm repo update
```

## Step 2 — Install the Rook operator
```bash
kubectl create namespace rook-ceph  # or let --create-namespace do it below
helm install rook-ceph rook-release/rook-ceph \
  --namespace rook-ceph --create-namespace \
  -f 01-operator-values.yaml

# watch it come up
kubectl -n rook-ceph get pods -w
```
Wait until `rook-ceph-operator-...` is `Running`.

## Step 3 — Edit the cluster values
Open `02-cluster-values.yaml` and replace the placeholder node names
(`worker-1`, `worker-2`, `worker-3`) and device names (`sdb`) with your
real ones. This is the step that prevents Rook from claiming every disk
on every node — do not skip it.

## Step 4 — Install the Ceph cluster + RGW + Dashboard
```bash
helm install rook-ceph-cluster rook-release/rook-ceph-cluster \
  --namespace rook-ceph \
  -f 02-cluster-values.yaml

kubectl -n rook-ceph get pods -w
```
This brings up: mons (3), mgr (1), OSDs (one per device you listed),
the RGW gateway pod, and the mgr dashboard module.

## Step 5 — Confirm cluster health
Install the toolbox (handy for any `ceph` CLI commands):
```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
```
If the toolbox isn't already deployed by the chart, apply:
```bash
kubectl apply -f https://raw.githubusercontent.com/rook/rook/master/deploy/examples/toolbox.yaml
```
You want to see `HEALTH_OK` (or `HEALTH_WARN` while OSDs are still settling).

## Step 6 — Access the Dashboard (UI)
Get the auto-generated admin password:
```bash
kubectl -n rook-ceph get secret rook-ceph-dashboard-password \
  -o jsonpath="{['data']['password']}" | base64 -d ; echo
```
Quick access via port-forward:
```bash
kubectl -n rook-ceph port-forward svc/rook-ceph-mgr-dashboard 8443:8443
# then open https://localhost:8443  (user: admin, password: from above)
```
Or apply `03-dashboard-ingress.yaml` (edit the host first) for permanent
external access through your ingress controller.

## Step 7 — Create S3 credentials for RGW
```bash
kubectl apply -f 04-object-store-user.yaml

kubectl -n rook-ceph get secret rook-ceph-object-user-rgw-store-s3-user \
  -o jsonpath='{.data.AccessKey}' | base64 -d; echo
kubectl -n rook-ceph get secret rook-ceph-object-user-rgw-store-s3-user \
  -o jsonpath='{.data.SecretKey}' | base64 -d; echo
```

## Step 8 — Get the RGW endpoint
```bash
kubectl -n rook-ceph get svc rook-ceph-rgw-rgw-store
```
In-cluster endpoint: `http://rook-ceph-rgw-rgw-store.rook-ceph.svc:80`
Expose it externally the same way (Ingress, LoadBalancer Service, or
NodePort) depending on your setup — not included here since it depends
on your ingress/load balancer choice.

## Step 9 — Test it
```bash
# using aws-cli configured with the access/secret key from Step 7
aws --endpoint-url http://<rgw-endpoint> s3 mb s3://test-bucket
aws --endpoint-url http://<rgw-endpoint> s3 ls
```

---

## Notes on space control (recap)
- `storage.useAllNodes/useAllDevices: false` + explicit `nodes:` list —
  only the disks you name become OSDs.
- `dataPool` uses erasure coding (2+1) instead of 3x replication —
  roughly 1.5x raw overhead instead of 3x.
- `metadataPool` replication set to `size: 2` — small pool anyway, but
  tunable.
- If using the PVC option instead, `volumeClaimTemplates.resources.requests.storage`
  is a hard per-OSD cap — total capacity = that value × `count`.
