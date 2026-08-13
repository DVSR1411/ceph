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


