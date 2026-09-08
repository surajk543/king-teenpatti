# Rolling the cluster back to one process

`install-cluster.sh` replaces `gameplay.service` (one Node process on :3000) with
`gameplay@1..3` (three workers on :3101–:3103) and rewrites the nginx site. Every step
below undoes one of its changes; do them in this order so nginx never points at a dead port.
Total time: about a minute. Players are disconnected once and reconnect.

Nothing here touches the database. The `cluster_workers` / `cluster_players` /
`cluster_rooms` tables stay (they are harmless: in single-process mode the server never reads
them and the "null registry" writes nothing; each worker also deletes its own rows as it stops,
so nothing is left pointing at a dead port), and every ledger row written by the workers is
ordinary — the money model is identical in both modes.

## 1. Start the single process

```bash
sudo systemctl enable --now gameplay.service
curl -s 127.0.0.1:3000/health          # {"ok":true,...} before you go on
```

`gameplay.service` was disabled, not deleted, by the installer. Its `.env` still says
`PORT=3000` (the workers ignored that line — a worker's port is `WORKER_BASE_PORT + WORKER_ID` —
but the single process honours it). It runs the same code — `WORKER_ID` is simply unset, which
is single-process mode.

## 2. Stop the workers

```bash
sudo systemctl disable --now 'gameplay@*' gameplay.target
systemctl status 'gameplay@*' --no-pager | grep -E 'Active|Loaded' || true
```

Every seated player on the workers loses their table (a stopped worker's tables do not move
anywhere) and reconnects — through nginx, still pointing at the workers, so they see connection
errors until step 3. Do 2 and 3 back to back.

## 3. Point nginx back at :3000

Preferred — the rollback site that also keeps the `/w1..3/socket.io/` paths alive (a client that
saved a worker path keeps working; the single process tells it `worker.path: "/socket.io"` on
`session:ready` and it unlearns the worker path):

```bash
sudo cp /var/www/gameplay/king-teenpatti/server/ops/cluster/nginx-gameplay-single.conf /etc/nginx/sites-available/gameplay
sudo nginx -t && sudo systemctl reload nginx
```

Alternative — the exact pre-cluster site the installer backed up (no `/wN/` paths; a client
holding a saved worker path gets 404s until it falls back to the default path):

```bash
ls -t /etc/nginx/sites-available/gameplay.bak-*        # newest first
sudo cp /etc/nginx/sites-available/gameplay.bak-<stamp> /etc/nginx/sites-available/gameplay
sudo nginx -t && sudo systemctl reload nginx
```

Check: `curl -s https://api.sungamestudio.com/health` answers, and
`curl -s -o /dev/null -w '%{http_code}\n' 'https://api.sungamestudio.com/socket.io/?EIO=4&transport=polling'`
is 200.

## 4. Prometheus (optional, cosmetic)

The `king-teenpatti-w1..w3` jobs now scrape dead ports and show DOWN. Either leave them (they
come back with the next cluster install) or delete the three blocks from
`/etc/prometheus/prometheus.yml`, then `promtool check config` and `systemctl reload prometheus`.
Restore the `game-server` job on `127.0.0.1:3000` if it was removed. The dashboard's `sum(...)`
expressions are correct for one instance as well; "Workers up" reads 0 because the single
process publishes no `game_worker_info` — expected.

## 5. Remove the units (only if you are not coming back)

```bash
sudo rm /etc/systemd/system/gameplay@.service /etc/systemd/system/gameplay.target
sudo systemctl daemon-reload
```

## Going forward again

`sudo bash install-cluster.sh` — it is idempotent and repeats every step above in reverse,
backing up whatever nginx site it finds.
