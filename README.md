# Passbolt, TLS, and MariaDB Galera Cluster: A love story

Running passbolt against a three-node MariaDB Galera cluster is an easy way to explore high availability foundations before deploying to production. This lab walk-through uses the `gareth-galera-lab` repository to spin up a full stack locally, exercise replication, and confirm passbolt operates over mutual TLS.

---

## What You'll Build

- Three MariaDB 11.5 nodes in a Galera cluster with TLS-enabled replication and client auth (Galera is MariaDB’s synchronous clustering layer; it keeps every node current on each write rather than replaying changes later like asynchronous replicas)
- Valkey providing Redis-compatible caching for Passbolt sessions and queues (Valkey is the community-maintained fork of Redis 7, API-compatible with the upstream project; this lab pins `valkey/valkey:8.1.4-alpine`, the 2025-10-21 release)
- Passbolt Community Edition pointed at the cluster via HTTPS

We will generate certificates, launch the stack with Docker Compose, validate the database topology, and finish by logging into Passbolt.

---

## Prerequisites

- Docker Compose v2
- GNU `bash` >= 4 (macOS ships with 3.2; install a newer version, e.g. Homebrew's `/opt/homebrew/bin/bash`)
- Copy `env.example` to `.env` and customise values (MariaDB root/user passwords, Passbolt datasource, admin account)
- Optionally, an `sshuttle`-style VPN if you need remote connectivity to an internal network (not required for the lab)

Populate `.env` in the project root (these are the values used by this guide; feel free to change them, but keep the spacing/quoting intact if you do):

```bash
cp env.example .env
# edit .env to match your environment (passwords, hostnames, admin email, etc.)
```

Once the file is in place, every helper script loads it automatically. When you change a value, rerun `./scripts/start-lab.sh --reset` so the containers are recreated with the new credentials.

> Need a different cache or database build? Set `VALKEY_IMAGE` or `MARIADB_IMAGE` in `.env` (e.g. `VALKEY_IMAGE=valkey/valkey:8.1.4-alpine`, `MARIADB_IMAGE=mariadb:11.5`).  
> Resolved hostnames (`galera1.local`, `galera2.local`, `galera3.local`) should exist in `/etc/hosts` or DNS when you run outside Docker.
> **Tip:** With `.env` ready, you can bring up the full stack in one go with `./scripts/start-lab.sh --reset`. The script handles certificate generation, Galera bootstrap, Valkey/passbolt startup, and the smoke tests covered below.

---

## When Galera is (and isn't) the right choice

For a single Passbolt instance, a standalone MariaDB server is still the lowest-effort option: simpler backups, fewer moving parts, and lower resource overhead. Galera shines when you need synchronous failover, zero data loss guarantees, or rolling maintenance with continuous service. The MariaDB usage guide calls out these trade-offs explicitly: multi-primary clusters eliminate replication lag but add operational complexity, so treat Galera as the "step up" once availability requirements outgrow a single node.[^2]

The Galera team itself positions the cluster for situations that demand active-active writes, WAN clustering, and disaster-recovery replicas that stay in sync without lag, all of which map neatly to passbolt's need for continuous credential access.[^9] Those same scenarios are where TLS-secured replication really matters: when nodes live in different racks, buildings, or subnets, you're relying on the certificates to authenticate peers and encrypt sensitive state transfers instead of trusting the network perimeter.

That's why this demo is a bit of a Trojan horse: it looks like a Galera lab, but the real lesson is how mutual TLS unlocks secure database topologies that aren't confined to a single subnet. By issuing mTLS material for both replication and application clients, you can spread `galera1.example.com`, `galera2.example.com`, and `galera3.example.com` across IPv4 or IPv6 segments without bending firewalls into pretzels. Routing only needs to carry the ports; the TLS layer enforces who can talk to whom and keeps the data encrypted in transit.

---

## Step 0 - Generate Demo GPG Keys (Optional but Handy)

I've included a script that creates gpg keys for demonstration users. By default it creates material for `ada@passbolt.com` (passphrase equals the email), but you can pass additional `email:Full Name` pairs if you need more identities.

```bash
./scripts/generate-demo-gpg.sh
# or e.g. ./scripts/generate-demo-gpg.sh \
#   "ada@passbolt.com:Ada Lovelace" \
#   "betty@passbolt.com:Betty Holberton"
```

Outputs land under `keys/gpg/`, producing `<email>.key` and `<email>.pub` files. When the Passbolt web installer asks for Ada's private key, use `keys/gpg/ada@passbolt.com.key` with passphrase `ada@passbolt.com`.

---

## Step 1 - Generate Certificates

The `scripts/generate-certs.sh` helper issues a root CA, server certs for each Galera node, and a mutual TLS client cert for Passbolt. Because the script uses associative arrays, invoke it with the modern bash binary:

```bash
/opt/homebrew/bin/bash ./scripts/generate-certs.sh
```

Outputs land in `certs/` and are mounted automatically by Compose.

> **Gotcha:** Running the script with macOS' default bash 3.2 triggers `unbound variable` errors. Always call the Homebrew bash (or any 4.x/5.x build).

For a broader overview of how Passbolt expects TLS to be configured in production, review the official TLS certificate guidance.[^8]

> **What is mTLS?**  
> Mutual TLS (often abbreviated mTLS) means *both* sides of a TLS connection present and verify X.509 certificates before any application data flows. Instead of only the client checking the server certificate (standard HTTPS), the server also checks the client's certificate, so each party cryptographically authenticates the other.[^10] That’s why this lab generates certificates for every Galera node and for passbolt itself—the database tier only accepts clients that can prove they are the expected service.

---

## Step 2 - Bootstrap the Galera Cluster

Bring up the first node on its own so it can form a primary component (a quorum-owning group that can accept writes; see the [terminology cheat sheet](#galera-terminology-cheat-sheet)):

```bash
docker compose up -d galera1
docker compose logs --no-color galera1
```

Confirm Galera reports `Primary` (the cluster must form one “primary component” to accept writes; see [Galera terminology cheat sheet](#galera-terminology-cheat-sheet)):

```bash
docker compose exec galera1 mariadb \
  -uroot -p"$MARIADB_ROOT_PASSWORD" \
  -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
```

Next, start the remaining nodes:

```bash
docker compose up -d galera2 galera3
```

Verify all three nodes have joined:

```bash
docker compose exec galera1 mariadb \
  -uroot -p"$MARIADB_ROOT_PASSWORD" \
  -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
# Expect Value = 3
```

### Health Checks Over Unix Sockets

The stock Compose file ships with `mysqladmin` health checks, but the MariaDB 11.5 image only exposes `mariadb-admin`. Additionally, TLS hostname verification fails because the container's hostname is not `galera1.local`. Updating the health check to use the Unix socket keeps the dependency graph happy and the checks stay inside the container instead of making TLS connections.

```yaml
healthcheck:
  test: ["CMD-SHELL", "mariadb-admin ping -uroot -p\"$${MARIADB_ROOT_PASSWORD}\" --socket=/run/mysqld/mysqld.sock"]
```

After tweaking the YAML, recreate the services (`docker compose up -d galera1 galera2 galera3`) to see them transition to `healthy`.

### Replication & TLS Validation

Write a row through node 1 and read it back via node 2 (a quick proof that writes replicate and commits are visible cluster-wide):

```bash
docker compose exec galera1 mariadb \
  -u"$DATASOURCES_DEFAULT_USERNAME" -p"$DATASOURCES_DEFAULT_PASSWORD" "$DATASOURCES_DEFAULT_DATABASE" \
  -e "CREATE TABLE galera_probe (id INT PRIMARY KEY AUTO_INCREMENT, note VARCHAR(255)); \
      INSERT INTO galera_probe (note) VALUES ('bootstrapped via galera1');"

docker compose exec galera2 mariadb \
  -u"$DATASOURCES_DEFAULT_USERNAME" -p"$DATASOURCES_DEFAULT_PASSWORD" "$DATASOURCES_DEFAULT_DATABASE" \
  -e "SELECT * FROM galera_probe;"
```

Check that connections negotiate TLS (MariaDB exposes the negotiated cipher via `SHOW STATUS LIKE 'Ssl_cipher';`):

```bash
docker compose exec galera1 mariadb \
  -u"$DATASOURCES_DEFAULT_USERNAME" -p"$DATASOURCES_DEFAULT_PASSWORD" "$DATASOURCES_DEFAULT_DATABASE" \
  -e "SHOW STATUS LIKE 'Ssl_cipher';"
```

You should see `TLS_AES_256_GCM_SHA384`.

### TLS Everywhere

- **Galera replication** uses the certificates mounted into each node (`server-cert.pem`, `server-key.pem`, `ca.pem`) via `wsrep_provider_options`, so node-to-node state transfers run over TLS.
- **passbolt client traffic** is forced over TLS by `config/mariadb/init/02-enforce-ssl.sql`, and the environment variables point passbolt at `/etc/passbolt/db-*.{crt,key}`. The cipher check above confirms the connection negotiates TLS successfully.  
- **Account policy** mirrors MariaDB's recommendation to require TLS on sensitive users: `ALTER USER 'passbolt'@'%' REQUIRE SSL;` ensures credentials are never sent in cleartext, aligning with the server's TLS-intention guidance.[^3]  
- **Server capability** can be confirmed with `SHOW GLOBAL VARIABLES LIKE 'have_ssl';`. A `YES` value indicates the engine loaded TLS support, matching the secure-connections checklist from MariaDB.[^4]

---

## Step 3 - Start Valkey and Passbolt

> **Why no ProxySQL?**  
> ProxySQL's Docker image currently ships without a full certificate chain on its frontend listener, which causes strict clients to reject the TLS handshake (see [issue #3788](https://github.com/sysown/proxysql/issues/3788)). Rather than keep a broken proxy in the loop, this demo connects Passbolt directly to the Galera nodes. You can reintroduce HAProxy/ProxySQL later if you need health-aware load balancing.

With the database tier stable, launch the remaining services:

```bash
docker compose up -d valkey passbolt
```

Map Passbolt's internal HTTPS listener to the host for convenience (already committed to `docker-compose.yaml`):

```yaml
passbolt:
  ports:
    - "443:443"
```

### Redis Engine Fix

Passbolt expects a single backslash in the cache classname. Ensure your environment block reads:

```yaml
CACHE_CAKECORE_CLASSNAME: 'Cake\Cache\Engine\RedisEngine'
```

Without the fix, the healthcheck throws `BadMethodCallException` while building the cache registry.

Once Passbolt reports `healthy`, run the built-in diagnostics:

```bash
docker compose exec passbolt \
  su -s /bin/bash -c "/usr/share/php/passbolt/bin/cake passbolt healthcheck" www-data
```

Expect warnings about self-signed certificates (acceptable for the lab). You can now browse to `https://passbolt.local` (trust the generated root CA in your browser) and complete the web setup flow. The invitation link issued after creating the first user should resolve successfully.

### Switching database nodes for testing

Passbolt reads the target node from `DATASOURCES_DEFAULT_HOST` (default `galera1.local`). To simulate a failover:

1. Update `.env` with `DATASOURCES_DEFAULT_HOST=galera2.local` (or `galera3.local`).
2. Restart only the application container so it picks up the change:

   ```bash
   docker compose up -d passbolt
   ```

3. Run `./scripts/check-stack.sh` to ensure the healthcheck still passes.

Repeat the process to flip back to `galera1` once you're done testing.

---

## Playbooks

### Rotate TLS certificates with a controlled pause

Use this drill to rotate the certificates without blowing away the cluster volumes. The cluster is paused briefly while the certificates are replaced; in production you’d point applications at another writer (or stagger node restarts) if you require continuous service.

1. Quiesce the application:

   ```bash
   docker compose stop passbolt
   ```

2. Stop the database nodes in reverse order so the primary is last to shut down. This ensures `galera1` records `safe_to_bootstrap=1` in its `grastate.dat` (see [terminology](#galera-terminology-cheat-sheet)).

   ```bash
   docker compose stop galera3
   docker compose stop galera2
   docker compose stop galera1
   ```

   Optional sanity check:

   ```bash
   docker compose run --rm galera1 cat /var/lib/mysql/grastate.dat
   ```

   You should see `safe_to_bootstrap: 1`. If not, identify the node with the highest `seqno` and set its flag to `1` before continuing (details in the [terminology cheat sheet](#galera-terminology-cheat-sheet)).

3. Regenerate the TLS material:

   ```bash
   /opt/homebrew/bin/bash ./scripts/generate-certs.sh
   ```

4. Bring the cluster back online:

   ```bash
   docker compose up -d galera1
   docker compose up -d galera2
   docker compose up -d galera3
   ```

   Wait for `galera1` to report `healthy` (`docker compose ps`) before starting the peers.

5. Restart passbolt and verify the stack:

   ```bash
   docker compose up -d passbolt
   ./scripts/check-stack.sh
   ```

If `check-stack.sh` fails, inspect the relevant logs (`docker compose logs --tail=100 passbolt galera1`) and confirm the regenerated certificates exist under `certs/` with hostnames that match your `.env`.

### Restore a node from scratch

Practice the donor/recipient flow by wiping a node and letting it rejoin via SST (see [terminology](#galera-terminology-cheat-sheet) for a refresher on SST vs IST and donor roles).

```bash
# Stop the target node (galera2 in this example)
docker compose stop galera2

# Remove its data directory so SST is required
docker compose run --rm galera2 bash -c 'rm -rf /var/lib/mysql/*'

# Bring the node back and observe donor selection (watch for "State transfer" in logs)
docker compose up -d galera2

# Confirm cluster size returns to 3
docker compose exec galera1 mariadb \
  -uroot -p"$MARIADB_ROOT_PASSWORD" \
  -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
```

Expected result: `wsrep_cluster_size` reports `Value: 3` after SST completes. If it stalls, check `docker compose logs galera2` for credential or certificate errors (and confirm whether the join fell back to SST or IST—see the [terminology cheat sheet](#galera-terminology-cheat-sheet)).

### Backup and restore rehearsal

This flow captures a physical backup from a replica node, prepares it, and restores it onto `galera1`.

```bash
# Take a hot backup from galera2
docker compose exec galera2 mariabackup --backup --target-dir=/tmp/backup

# Prepare the backup for restore
docker compose exec galera2 mariabackup --prepare --target-dir=/tmp/backup

# Stop galera1 and wipe its datadir
docker compose stop galera1
docker compose run --rm galera1 bash -c 'rm -rf /var/lib/mysql/*'

# Copy the prepared backup into galera1's datadir
docker compose exec galera2 bash -c 'tar -C /tmp/backup -cf - .' | \
  docker compose exec -T galera1 bash -c 'tar -C /var/lib/mysql -xf -'

# Bring galera1 back online and verify cluster health
docker compose up -d galera1
./scripts/check-stack.sh
```

If `check-stack.sh` reports a failure, inspect `docker compose logs galera1` to ensure the restored files have the correct ownership (`mysql:mysql`) and permissions.

### Flip passbolt to another writer

Simulate an application-level failover by pointing passbolt at a different node.

```bash
# Update the target host in .env (set to galera2.local)
sed -i '' 's/^DATASOURCES_DEFAULT_HOST=.*/DATASOURCES_DEFAULT_HOST=galera2.local/' .env

# Restart the application container so it picks up the change
docker compose up -d passbolt

# Run the health check to confirm passbolt can reach galera2
./scripts/check-stack.sh
```

Restore the original host (`galera1.local`) when you're done:

```bash
sed -i '' 's/^DATASOURCES_DEFAULT_HOST=.*/DATASOURCES_DEFAULT_HOST=galera1.local/' .env
docker compose up -d passbolt
./scripts/check-stack.sh
```

---

### Galera monitoring quick reference

Drop these commands into your shell while the lab is running; they work against the Compose services spun up in this repo. In the examples below we lean on `MYSQL_PWD="$MARIADB_ROOT_PASSWORD"` so you don't have to fight with shell quoting.

- **Cluster summary (size, state, peer list)**

  ```bash
  docker compose exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" galera1 mariadb \
    -uroot \
    -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_local_state_comment','wsrep_cluster_status','wsrep_incoming_addresses');"
  ```

  ```text
  Variable_name     Value
  wsrep_local_state_comment  Synced
  wsrep_incoming_addresses   galera1.local:0,galera2.local:0,galera3.local:0
  wsrep_cluster_size  3
  wsrep_cluster_status Primary
  ```

- **Flow-control pressure (values approaching 1 mean writes are being throttled)**

  ```bash
  docker compose exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" galera1 mariadb \
    -uroot \
    -e "SHOW STATUS LIKE 'wsrep_flow_control_paused';"
  ```

  ```text
  Variable_name     Value
  wsrep_flow_control_paused  0
  ```

- **Current cluster members and their advertised addresses**

  ```bash
  docker compose exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" galera1 mariadb \
    -uroot \
    -e "SELECT node_name, node_incoming_address FROM mysql.wsrep_cluster_members;"
  ```

  ```text
  node_name  node_incoming_address
  galera1    galera1.local:0
  galera2    galera2.local:0
  galera3    galera3.local:0
  ```

- **Recent Galera log entries (joins, SST progress, authentication issues)**

  ```bash
  docker compose exec galera1 tail -n 5 /var/lib/mysql/galera1.err
  ```

  ```text
  2025-11-13  5:19:00 0 [Note] WSREP: 2.0 (galera3): State transfer from 1.0 (galera2) complete.
  2025-11-13  5:19:00 0 [Note] WSREP: Member 2.0 (galera3) synced with group.
  2025-11-13  5:19:00 0 [Note] WSREP: (379a49b9-834c, 'ssl://0.0.0.0:4567') turning message relay requesting off
  2025-11-13  5:23:51 57 [Warning] Access denied for user 'root'@'localhost' (using password: NO)
  2025-11-13  5:24:02 60 [Warning] Access denied for user 'root'@'localhost' (using password: NO)
  ```

- **Container health overview**

  ```bash
  docker compose ps
  ```

  ```text
  NAME              IMAGE                         COMMAND                  STATUS
  galera_galera1    mariadb:11.5                  "docker-entrypoint…"     Up 6 minutes (healthy)
  galera_galera2    mariadb:11.5                  "docker-entrypoint…"     Up 6 minutes (healthy)
  galera_galera3    mariadb:11.5                  "docker-entrypoint…"     Up 6 minutes (healthy)
  galera_passbolt   passbolt/passbolt:latest-ce   "/bin/bash -ceu /doc…"   Up 6 minutes (healthy)
  galera_valkey     valkey/valkey:8.1.4-alpine    "docker-entrypoint…"     Up 7 minutes
  ```

- **Full-stack probe (Galera quorum + passbolt healthcheck)**

  ```bash
  ./scripts/check-stack.sh
  ```

  (See the troubleshooting section above for representative output.)

All of the `mariadb` invocations accept `--defaults-file=/etc/mysql/conf.d/docker.cnf` if you prefer not to pass credentials inline. Swap `galera1` for `galera2` or `galera3` to inspect donors/recipients directly during SST or flow-control events.

### Galera terminology cheat sheet

- **Primary component** – the set of nodes that currently has quorum and is allowed to accept writes. `SHOW STATUS LIKE 'wsrep_cluster_status';` returns `Primary` when a node belongs to that component.
- **`grastate.dat` / `safe_to_bootstrap` / `seqno`** – Galera records the last committed transaction ID (`seqno`) on each node. The node that shut down cleanly with the highest `seqno` sets `safe_to_bootstrap=1`, signalling it can safely bootstrap the cluster after a restart.
- **SST (State Snapshot Transfer)** – a full copy of the database streamed to a joining node; wipes and replaces the recipient’s datadir.
- **IST (Incremental State Transfer)** – a differential catch-up that replays recent transactions from the donor’s Galera cache (GCache). Used when the recipient was offline briefly.
- **Donor / Recipient** – during SST/IST the donor streams data to the recipient (joining) node; Galera logs call out these roles explicitly.
- **Flow control / `wsrep_flow_control_paused`** – Galera slows writers when replicas fall behind. This metric shows how much of the last interval the cluster spent paused (e.g. `0.5` ≈ 50% of the time).
- **`wsrep_local_state_comment`** – human-readable node state (`Joining`, `Donor`, `Synced`, etc.).
- **`wsrep_OSU_method` (TOI vs RSU)** – Total Order Isolation (TOI) runs DDL cluster-wide; Rolling Schema Upgrade (RSU) temporarily isolates a single node for the change.
- **GCache** – Galera’s cache of recent write-sets, used to serve IST. If a recipient’s gap exceeds the cache, Galera falls back to SST.
- **`gcomm://`** – the Galera communication URL. In this lab node 1 uses an empty address list so it can bootstrap; production deployments list every peer host.
- **`wsrep_provider` / `libgalera_smm.so`** – the Galera replication plugin that MariaDB loads to provide synchronous clustering.
- **`wsrep_sst_method=rsync`** – instructs Galera to use `rsync` for SST (alternatives include `mariabackup`, `xtrabackup`, etc.).
- **Garbd (Galera arbitrator)** – a lightweight process that participates in quorum without storing data—useful when you have an even number of database nodes.

---

## Troubleshooting Notes

- **Bash 3 vs 5:** Using macOS' default shell will fail the certificate script. Install and call Bash 5 explicitly.
- **MariaDB Health Checks:** Replace `mysqladmin` with `mariadb-admin` and use the socket to bypass TLS hostname validation.
- **Passbolt Cache Engine:** A mis-escaped environment value (`Cake\\Cache\\Engine\\RedisEngine`) causes the application bootstrap to throw.
- **Port Exposure:** Exposing Passbolt on `443` simplifies local navigation; production setups usually sit behind a reverse proxy or load balancer.
- **Smoke tests:** Run `./scripts/check-stack.sh` any time to re-validate Galera status and the Passbolt health check without repeating the full bring-up sequence.

---

## Operating & Managing the Cluster

The goal is to give a MariaDB administrator familiar tasks (restart, backup, restore, migrate) and show the Galera-specific twists. Every walkthrough below mirrors the MariaDB Galera documentation so you can apply the same flow to physical or cloud hosts.[^2] If you bump into terms like SST, IST, or flow control while reading, refer back to the [Galera terminology cheat sheet](#galera-terminology-cheat-sheet) just above.

### Bootstrap and recovery

Why: After a full outage you must bring only the freshest node online first; otherwise the cluster may form diverging primary components.

Steps:

1. Inspect `grastate.dat` on each node to find the highest `seqno` or a `safe_to_bootstrap=1` flag (see the [terminology cheat sheet](#galera-terminology-cheat-sheet) for definitions):  
   `docker compose exec galera1 cat /var/lib/mysql/grastate.dat`
2. If the best candidate shows `seqno = -1`, recover the real position:  
   `docker compose exec galera1 sh -c 'mariadb --execute "SET GLOBAL wsrep_on=OFF"; /usr/sbin/mariadbd --wsrep-recover --user=mysql'`.[^7]
3. On that node only, bootstrap the cluster: `docker compose exec galera1 galera_new_cluster`.  
   Bring the remaining nodes up normally; expect IST when their GCache is still hot, SST otherwise.[^2][^6]

### Bring a node back

Why: Daily maintenance still happens per node; Galera adds donor/recipient behaviour you should confirm.

Steps:

1. For routine restarts: `docker compose restart galera2`. Galera keeps the node in `Synced`.  
2. After a crash, stop the container, review `/var/lib/mysql/grastate.dat`, and start it again. If corruption is obvious, wipe the datadir (in production you would re-image the server) and let an SST rebuild it (see the [Galera terminology cheat sheet](#galera-terminology-cheat-sheet)).  
3. When the cluster lost quorum, bootstrap a single node as above, verify `wsrep_cluster_status=Primary`, then start peers sequentially to regain size without split-brain.[^2]

### Backups and restores

Why: You still need point-in-time backups; Galera just changes where you run them and how restores re-seed the cluster.

Steps:

1. Hot backup from a non-writer node:  
   `docker compose exec galera2 mariabackup --backup --target-dir=/tmp/backup`.[^2]  
   Copy it out (`docker cp`) and run `mariabackup --prepare` so the files are consistent.
2. Restore by stopping all nodes, placing the prepared backup on a single node (e.g., `galera1`), bootstrapping it, and letting the others rejoin via IST/SST (incremental vs snapshot transfer; see the [terminology cheat sheet](#galera-terminology-cheat-sheet)). That mirrors the documented "restore one, let others sync" pattern.[^2]
3. Logical dumps remain valid (`mariadb-dump --single-transaction`), but physical backups preserve GTID metadata required for clean SST handshakes.

### Schema changes

Why: Large DDL in Galera blocks the cluster via Total Order Isolation; you need a plan before the change window.

Steps:

1. For quick changes, run the DDL as usual and monitor `wsrep_flow_control_paused` to ensure the cluster is not throttled (flow-control is explained in the [terminology cheat sheet](#galera-terminology-cheat-sheet)).  
2. For heavyweight migrations, temporarily switch one node to Rolling Schema Upgrade (RSU) instead of the default Total Order Isolation (TOI):  
   `docker compose exec galera1 mariadb --execute "SET GLOBAL wsrep_OSU_method='RSU'; ALTER TABLE ...; SET GLOBAL wsrep_OSU_method='TOI';"`.[^2]  
   Only that node accepts writes during RSU, so keep the change window tight.

### Monitoring and flow control

Why: Galera's consensus layer exposes extra status variables; treat them as first-class SLO signals.

Steps:

1. Run `SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size';` and `'wsrep_local_state_comment';` to prove quorum and node state (`Synced`, `Donor`, `Joining`—all defined in the [terminology cheat sheet](#galera-terminology-cheat-sheet)).  
2. Watch `'wsrep_flow_control_paused';` anything sustained above ~0.5 means replicas are slowing the writer.[^2]  
3. Tail `/var/log/mysql/galera*.err` for `Flow control paused` or `Non-Primary view` entries so you catch congestion or split-brain conditions early.

### Multi-site and latency

Why: Standard MariaDB replication tolerates latency; Galera requires tight RTT and extra quorum tuning.

Steps:

1. Keep RTT under a few milliseconds; above 5-10 ms writes will feel sluggish because every transaction waits for consensus.[^2]  
2. Group nodes with `gmcast.segment` so intra-site traffic stays local (terminology recap in the [cheat sheet](#galera-terminology-cheat-sheet)).  
3. Increase `evs.suspect_timeout` / `evs.inactive_timeout` to match WAN latency and add a Galera Arbitrator (`garbd`) if you only have two DB nodes per site.

### Configuration deep dive

Why: Most "normal" MariaDB knobs still apply; these are the Galera-specific ones to carry into production.

1. `wsrep_cluster_address=gcomm://` on node 1 is a lab shortcut so an empty datadir bootstraps automatically. In production list every peer FQDN so the node rejoins the existing component instead (see the [terminology cheat sheet](#galera-terminology-cheat-sheet) for notes on `gcomm://`).[^6]  
2. TLS directives (`socket.ssl_ca`, `socket.ssl_cert`, `socket.ssl_key`) and `require_secure_transport=ON` keep both replication and client traffic encrypted; match them to your site-issued certificates.[^5]  
3. The repo drops its overrides into `/etc/mysql/mariadb.conf.d/z-custom-my.cnf`, following MariaDB's advice to keep vendor configs untouched for easier upgrades.[^5]

### Next steps

1. Automate the Passbolt GPG fingerprint/JWT provisioning immediately after bootstrap so the healthcheck is clean.  
2. Revisit ProxySQL or HAProxy once the TLS frontend issue mentioned earlier is resolved; either proxy can front the Galera writer hostgroup for the application.  
3. Schedule recurring `mariabackup` exports to external storage and rehearse the restore flow so the wider Passbolt HA pattern is battle-tested.[^1]

[^1]: [How to Set-Up a Highly-Available Passbolt Environment](https://www.passbolt.com/blog/how-to-set-up-a-highly-available-passbolt-environment)
[^2]: [MariaDB Galera Cluster Usage Guide](https://mariadb.com/docs/galera-cluster/readme/mariadb-galera-cluster-usage-guide)
[^3]: [MariaDB Server - ALTER USER TLS Options](https://mariadb.com/docs/server/reference/sql-statements/account-management-sql-statements/alter-user/#tls-options)
[^4]: [MariaDB Server - Secure Connections Overview](https://mariadb.com/docs/server/security/securing-mariadb/encryption/data-in-transit-encryption/secure-connections-overview)
[^5]: [MariaDB Server - Enabling TLS on MariaDB Server](https://mariadb.com/docs/server/security/securing-mariadb/encryption/data-in-transit-encryption/data-in-transit-encryption-enabling-tls-on-mariadb-server)
[^6]: [MariaDB Galera Cluster Guide - Configure `galera.cnf`](https://mariadb.com/docs/galera-cluster/galera-cluster-quickstart-guides/mariadb-galera-cluster-guide/#id-4.-configure-galera-cluster-galera.cnf-on-each-node)
[^7]: [MariaDB Galera Cluster System Variables - `wsrep_recover`](https://mariadb.com/docs/galera-cluster/reference/galera-cluster-system-variables/#wsrep_recover)
[^8]: [Passbolt TLS Certificates](https://www.passbolt.com/docs/hosting/configure/tls/)
[^9]: [MariaDB Galera Use Cases](https://mariadb.com/docs/galera-cluster/galera-use-cases)
[^10]: [Wikipedia – Mutual Authentication (mTLS)](https://en.wikipedia.org/wiki/Mutual_authentication#mTLS)

---

## Clean Up

When you are done experimenting:

```bash
docker compose down -v
```

This removes containers and volumes so you can re-run the bootstrap from scratch.
