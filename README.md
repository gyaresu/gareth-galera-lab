# Passbolt, TLS, and MariaDB Galera Cluster: A love story

Running passbolt against a three-node MariaDB Galera cluster is an easy way to explore high availability foundations before deploying to production. This lab walkthrough uses the `gareth-galera-lab` repository to spin up a full stack locally, exercise replication, and confirm passbolt operates over mutual TLS.

---

## What You'll Build

- Three MariaDB 11.8 nodes in a Galera cluster with TLS-enabled replication and client auth (Galera is MariaDB's synchronous clustering layer; it keeps every node current on each write rather than replaying changes later like asynchronous replicas)
- Valkey providing Redis-compatible caching for Passbolt sessions and cache (Valkey is the community-maintained fork of Redis 7, API-compatible with the upstream project; this lab pins `valkey/valkey:8.1.4-alpine`, the 2025-10-21 release)
- Passbolt Community Edition pointed at the cluster via HTTPS

We will generate certificates, launch the stack with Docker Compose, validate the database topology, and complete the user setup in the browser.

---

## Prerequisites

- Docker Compose v2
- GNU `bash` >= 4 (macOS ships with 3.2; install a newer version, e.g. Homebrew's `/opt/homebrew/bin/bash`)
- Copy `env.example` to `.env` and customise values (MariaDB root/user passwords, Passbolt datasource, admin account)

Populate `.env` in the project root (these are the values used by this guide; feel free to change them, but keep the spacing/quoting intact if you do):

```bash
cp env.example .env
# edit .env to match your environment (passwords, hostnames, admin email, etc.)
```

Once the file is in place, every helper script loads it automatically. When you change a value, rerun `./scripts/start-lab.sh --reset` so the containers are recreated with the new credentials.

> Need a different cache or database build? Set `VALKEY_IMAGE` or `MARIADB_IMAGE` in `.env` (e.g. `VALKEY_IMAGE=valkey/valkey:8.1.4-alpine`, `MARIADB_IMAGE=mariadb:11.8`).  
> Resolved hostnames (`galera1.local`, `galera2.local`, `galera3.local`) should exist in `/etc/hosts` or DNS when you run outside Docker.
> **Tip:** With `.env` ready, you can bring up the full stack in one go with `./scripts/start-lab.sh --reset`. The script handles certificate generation, Galera bootstrap, Valkey/passbolt startup, and the smoke tests covered below.

---

## When Galera is (and isn't) the right choice

For a single Passbolt instance, a standalone MariaDB server is still the lowest-effort option: simpler backups, fewer moving parts, and lower resource overhead. Galera shines when you need synchronous failover, zero data loss guarantees, or rolling maintenance with continuous service. The MariaDB usage guide calls out these trade-offs explicitly: multi-primary clusters eliminate replication lag but add operational complexity, so treat Galera as the "step up" once availability requirements outgrow a single node.[^2]

The Galera team itself positions the cluster for situations that demand active-active writes, WAN clustering, and disaster-recovery replicas that stay in sync without lag, all of which map neatly to passbolt's need for continuous credential access.[^9] Synchronous replication works over WAN networks - the delay is proportional to RTT and only affects commit operations, while reads and writes execute locally for fast user experience. See the [WAN clustering](#wan-clustering) section for details on how it works and when to use it.

Those same scenarios are where TLS-secured replication really matters: when nodes live in different racks, buildings, or subnets, you're relying on the certificates to authenticate peers and encrypt sensitive state transfers instead of trusting the network perimeter.

That's why this demo is a bit of a Trojan horse: it looks like a Galera lab, but the real lesson is how mutual TLS unlocks secure database topologies that aren't confined to a single subnet. By issuing mTLS material for both replication and application clients, you can spread `galera1.example.com`, `galera2.example.com`, and `galera3.example.com` across IPv4 or IPv6 segments without complex firewall rules. Routing only needs to carry the ports; the TLS layer enforces who can talk to whom and keeps the data encrypted in transit.

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
> Mutual TLS (often abbreviated mTLS) means *both* sides of a TLS connection present and verify X.509 certificates before any application data flows. Instead of only the client checking the server certificate (standard HTTPS), the server also checks the client's certificate, so each party cryptographically authenticates the other.[^10] That's why this lab generates certificates for every Galera node and for passbolt itself - the database tier only accepts clients that can prove they are the expected service.

---

## Step 2 - Bootstrap the Galera Cluster

Galera requires a Primary Component to accept writes. A Primary Component is the majority group of nodes (more than 50% of total nodes) that can process database queries and transactions. Nodes not in the Primary Component enter a non-primary state (read-only) and halt query processing to prevent data discrepancies. This prevents split-brain scenarios where network partitions could lead to parts of the cluster operating independently and accepting conflicting writes.

In a 3-node cluster, a majority is 2 nodes, so the cluster can tolerate the failure of 1 node and remain operational. With an even number of nodes (e.g., 2-node cluster), you need a Galera Arbitrator (`garbd`) to provide fault tolerance, as a single node failure would leave only 50% (not a majority).[^14]

Bring up the first node on its own so it can form a Primary Component:

```bash
docker compose up -d galera1
docker compose logs --no-color galera1
```

Confirm Galera reports `Primary` status. This means the node has formed a Primary Component and can accept writes. If you see any other value, the node cannot process transactions:

```bash
docker compose exec galera1 mariadb \
  -uroot -p"$MARIADB_ROOT_PASSWORD" \
  -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
```

You should see `wsrep_cluster_status` with value `Primary`.

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

The stock Compose file ships with `mysqladmin` health checks, but the MariaDB 11.8 image only exposes `mariadb-admin`. Additionally, TLS hostname verification fails because the container's hostname is not `galera1.local`. Updating the health check to use the Unix socket keeps the dependency graph happy and the checks stay inside the container instead of making TLS connections.

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

Once Passbolt reports `healthy`, run the healthcheck:

```bash
docker compose exec passbolt \
  su -s /bin/bash -c "/usr/share/php/passbolt/bin/cake passbolt healthcheck" www-data
```

Expect warnings about self-signed certificates (acceptable for the lab). The stack is now running and ready for user setup.

---

## Step 4 - Complete User Setup in Browser

If you're using `./scripts/start-lab.sh`, the admin user is automatically registered and the setup link is printed in the terminal output. Copy that setup link and open it in your browser.

If you started the services manually, you'll need to register the admin user first:

```bash
docker compose exec passbolt \
  su -s /bin/bash -c "/usr/share/php/passbolt/bin/cake passbolt register_user -u '${PASSBOLT_ADMIN_EMAIL}' -f '${PASSBOLT_ADMIN_FIRSTNAME}' -l '${PASSBOLT_ADMIN_LASTNAME}' -r '${PASSBOLT_ADMIN_ROLE}'" www-data
```

The setup link will be printed in the terminal output. Open it in your browser (trust the generated root CA when prompted) to complete the user setup.

Congratulations! You now have a fully operational Passbolt instance running against a three-node MariaDB Galera cluster with mutual TLS authentication. The cluster is replicating synchronously, all traffic is encrypted, and you can explore the playbooks below to practice common operational tasks.

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

Expected result: `wsrep_cluster_size` reports `Value: 3` after SST completes. If it stalls, check `docker compose logs galera2` for credential or certificate errors (and confirm whether the join fell back to SST or IST - see the [terminology cheat sheet](#galera-terminology-cheat-sheet)).

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

Simulate an application-level failover by pointing passbolt at a different node. This is useful when you need to perform maintenance on the current writer (e.g., restarting `galera1` while it has `wsrep_cluster_address=gcomm://` - see [Restarting the bootstrap node](#restarting-the-bootstrap-node-galera1)).

**Before flipping:** Verify the target node is in Primary Component and can accept writes:

```bash
# Check that galera2 is in Primary Component
docker compose exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" galera2 mariadb \
  -uroot \
  -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
```

You should see `wsrep_cluster_status` with value `Primary`. If it shows `Non-Primary`, the node is in non-primary state (read-only) and cannot accept writes - do not flip to it.

**Flip to the new writer:**

```bash
# Update the target host in .env (set to galera2.local)
sed -i '' 's/^DATASOURCES_DEFAULT_HOST=.*/DATASOURCES_DEFAULT_HOST=galera2.local/' .env

# Restart the application container so it picks up the change
docker compose up -d passbolt

# Run the health check to confirm passbolt can reach galera2
./scripts/check-stack.sh
```

**Restore the original host** (`galera1.local`) when you're done:

```bash
sed -i '' 's/^DATASOURCES_DEFAULT_HOST=.*/DATASOURCES_DEFAULT_HOST=galera1.local/' .env
docker compose up -d passbolt
./scripts/check-stack.sh
```

**Why this matters:** In Galera, all nodes in the Primary Component can accept writes, but nodes not in the Primary Component enter a non-primary state (read-only) and halt query processing. Flipping to a non-primary node would cause all database writes to fail. The Primary Component is the majority group of nodes (more than 50%) that can process transactions; nodes outside it are prevented from accepting writes to avoid split-brain scenarios (see the [terminology cheat sheet](#galera-terminology-cheat-sheet) for details).

---

### Galera monitoring quick reference

Drop these commands into your shell while the lab is running; they work against the Compose services spun up in this repo. In the examples below we lean on `MYSQL_PWD="$MARIADB_ROOT_PASSWORD"` so you don't have to fight with shell quoting.

- **Cluster summary (quorum, size, state, peer list)**

  Check quorum and Primary Component status. For a healthy cluster, `wsrep_cluster_status` must be `Primary` on all nodes. If it's anything else, the node cannot accept writes:

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

  **Understanding the values:**
  - `wsrep_cluster_status=Primary`: Node belongs to the Primary Component and can accept writes. Any other value means the node is in non-primary state (read-only) and cannot process transactions.
  - `wsrep_cluster_size`: Number of nodes in the current component. Should match your expected total (3 in this lab). If it's less than expected, some nodes may have lost connectivity.
  - `wsrep_cluster_state_uuid` and `wsrep_cluster_conf_id`: Must be identical across all nodes. If they differ, nodes are in different components (split-brain scenario). For a healthy cluster, these values must be the same on every node.

- **Flow-control pressure (fraction of time paused; 0.0 is healthy, 0.2+ indicates issues)**

  ```bash
  docker compose exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" galera1 mariadb \
    -uroot \
    -e "SHOW STATUS LIKE 'wsrep_flow_control_paused';"
  ```

  ```text
  Variable_name     Value
  wsrep_flow_control_paused  0
  ```

- **Receive queue size (high or increasing values indicate a slow node)**

  ```bash
  docker compose exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" galera1 mariadb \
    -uroot \
    -e "SHOW STATUS LIKE 'wsrep_local_recv_queue_avg';"
  ```

  ```text
  Variable_name     Value
  wsrep_local_recv_queue_avg  0.5
  ```

  A high or increasing value suggests a node struggling to keep up, likely triggering flow control. This is especially important to monitor in WAN deployments where network latency can cause queues to grow.

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
  galera_galera1    mariadb:11.8                  "docker-entrypoint…"     Up 6 minutes (healthy)
  galera_galera2    mariadb:11.8                  "docker-entrypoint…"     Up 6 minutes (healthy)
  galera_galera3    mariadb:11.8                  "docker-entrypoint…"     Up 6 minutes (healthy)
  galera_passbolt   passbolt/passbolt:5.7.0-1-ce   "/bin/bash -ceu /doc…"   Up 6 minutes (healthy)
  galera_valkey     valkey/valkey:8.1.4-alpine    "docker-entrypoint…"     Up 7 minutes
  ```

- **Full-stack probe (Galera quorum + passbolt healthcheck)**

  ```bash
  ./scripts/check-stack.sh
  ```

  (See the troubleshooting section above for representative output.)

All of the `mariadb` invocations accept `--defaults-file=/etc/mysql/conf.d/docker.cnf` if you prefer not to pass credentials inline. Swap `galera1` for `galera2` or `galera3` to inspect donors/recipients directly during SST or flow-control events.

### Galera terminology cheat sheet

- **Primary component** - the majority group of nodes that has quorum and can process database queries and transactions. Quorum is achieved when more than 50% of the total nodes are in communication. Nodes not in the Primary Component switch to a non-primary state, halting queries and becoming read-only to prevent data discrepancies. This prevents split-brain scenarios where network partitions could lead to parts of the cluster operating independently and accepting conflicting writes. Galera strongly prioritizes Consistency (from CAP theorem), so if quorum is lost, the cluster stops accepting writes until a Primary Component is re-established. Check with `SHOW STATUS LIKE 'wsrep_cluster_status';` - it returns `Primary` when a node belongs to that component. If the value is anything other than `Primary`, the node cannot accept writes and is in non-primary state (read-only).[^14]
- **`grastate.dat` / `safe_to_bootstrap` / `seqno`** - Galera records the last committed transaction ID (`seqno`) on each node. The node that shut down cleanly with the highest `seqno` sets `safe_to_bootstrap=1`, signalling it can safely bootstrap the cluster after a restart.
- **SST (State Snapshot Transfer)** - a full copy of the database streamed to a joining node; wipes and replaces the recipient's datadir.
- **IST (Incremental State Transfer)** - a differential catch-up that replays recent transactions from the donor's Galera cache (GCache). Used when the recipient was offline briefly.
- **Donor / Recipient** - during SST/IST the donor streams data to the recipient (joining) node; Galera logs call out these roles explicitly.
- **Flow control / `wsrep_flow_control_paused`** - When a slow node's receive queue exceeds `gcs.fc_limit` (default 100 write-sets), it broadcasts a PAUSE message. All nodes temporarily stop replicating new transactions until the slow node catches up. This metric shows the fraction of time paused since the last `FLUSH STATUS` (0.0 is healthy; 0.2 or higher indicates issues).[^11]
- **`wsrep_local_state_comment`** - human-readable node state (`Joining`, `Donor`, `Synced`, etc.).
- **`wsrep_OSU_method` (TOI vs RSU)** - Controls how schema changes (DDL - Data Definition Language statements like `CREATE TABLE`, `ALTER TABLE`, `DROP INDEX`) are applied. Total Order Isolation (TOI) applies DDL cluster-wide simultaneously on all nodes, ensuring schema consistency but blocking the entire cluster during the change. Rolling Schema Upgrade (RSU) temporarily isolates a single node for the change, allowing other nodes to continue serving traffic, but requires careful coordination to avoid schema conflicts.
- **GCache** - Galera's cache of recent write-sets, used to serve IST. If a recipient's gap exceeds the cache, Galera falls back to SST.
- **`gcomm://`** - the Galera communication URL. In this lab node 1 uses an empty address list so it can bootstrap; production deployments list every peer host.
- **`wsrep_provider` / `libgalera_smm.so`** - the Galera replication plugin that MariaDB loads to provide synchronous clustering.
- **`wsrep_sst_method=rsync`** - instructs Galera to use `rsync` for SST (alternatives include `mariabackup`, `xtrabackup`, etc.).
- **Garbd (Galera arbitrator)** - a lightweight process that participates in quorum without storing data - useful when you have an even number of database nodes.

---

## Troubleshooting Notes

- **Bash 3 vs 5:** macOS ships with Bash 3.2, but the certificate generation script requires Bash 4 or later. Install a newer version (e.g., via Homebrew: `/opt/homebrew/bin/bash`) and call it explicitly in the script or your shell.

- **MariaDB Health Checks:** The MariaDB Docker image uses `mariadb-admin` instead of the older `mysqladmin` command. When writing health checks, use `mariadb-admin` and connect via the Unix socket to bypass TLS hostname validation issues.

- **Passbolt Cache Engine:** Passbolt expects a single backslash in the cache classname environment variable. A mis-escaped value like `Cake\\Cache\\Engine\\RedisEngine` (double backslash) causes the application bootstrap to fail. Ensure your `.env` has `CACHE_CAKECORE_CLASSNAME: 'Cake\Cache\Engine\RedisEngine'` with a single backslash.

- **Port Exposure:** This lab exposes Passbolt on port `443` to simplify local navigation. In production, Passbolt typically sits behind a reverse proxy (like nginx or Apache) or a load balancer that handles TLS termination and routing.

- **Smoke tests:** The `./scripts/check-stack.sh` script validates both Galera cluster health and Passbolt's healthcheck endpoint. Run it anytime to re-validate the stack without repeating the full bring-up sequence.

---

## Operating & Managing the Cluster

The goal is to give a MariaDB administrator familiar tasks (restart, backup, restore, migrate) and show the Galera-specific twists. Every walkthrough below mirrors the MariaDB Galera documentation so you can apply the same flow to physical or cloud hosts.[^2] If you bump into terms like SST, IST, or flow control while reading, refer back to the [Galera terminology cheat sheet](#galera-terminology-cheat-sheet) just above.

### Bootstrap and recovery

Why: After a full outage, quorum is lost and no Primary Component exists. All nodes enter a non-primary state and cannot accept writes. You must manually bootstrap from the most advanced node; otherwise multiple nodes could form separate Primary Components (split-brain), leading to data conflicts. Galera prioritizes Consistency over Availability, so it stops accepting writes until a Primary Component is re-established. Never execute the bootstrap command on multiple nodes simultaneously, as this will create independent, active clusters with diverging data.[^14]

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

#### Recovering a node in non-primary state

If a node enters non-primary state (check with `SHOW STATUS LIKE 'wsrep_cluster_status';` - it will show `Non-Primary` instead of `Primary`), it has lost connection to the Primary Component and is rejecting all queries to prevent data inconsistency.

**For a single node in non-primary state (other nodes are still Primary):**

1. Check if the node can reconnect to the cluster:

   ```bash
   docker compose logs --tail=50 galera2
   ```

   Look for network errors, certificate issues, or authentication failures.

2. Restart the node - it should automatically rejoin the Primary Component:

   ```bash
   docker compose restart galera2
   ```

3. Verify it rejoined:

   ```bash
   docker compose exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" galera2 mariadb \
     -uroot \
     -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   ```

   It should show `Primary` after rejoining.

**For a full cluster outage (all nodes in non-primary state):**

This requires manual bootstrap from the most advanced node. See the [Bootstrap and recovery](#bootstrap-and-recovery) section above for the complete procedure.

**Note:** By default, nodes in non-primary state reject all queries (including reads). If you need to allow read-only queries on a non-primary node (they may be stale), you can set `wsrep_dirty_reads=ON`, but this is generally not recommended as the data may be inconsistent. See the [MariaDB documentation on recovering a Primary Component](https://mariadb.com/docs/galera-cluster/high-availability/recovering-a-primary-component) for official recovery procedures.[^15]

#### Restarting the bootstrap node (galera1)

If you restart `galera1` while `galera2` and `galera3` are still running, you may encounter a bootstrap error. This happens because:

- `galera1` has `wsrep_cluster_address=gcomm://` (empty) in its config, which tells it to bootstrap
- But it has `safe_to_bootstrap: 0` because it wasn't the last node to shut down
- Galera refuses to bootstrap for safety, but it also can't join because the config says to bootstrap

**Solution:** Before restarting `galera1` while other nodes are running, edit `config/mariadb/node1/galera.cnf`:

1. Comment out the empty `gcomm://` line (currently: `wsrep_cluster_address=gcomm://`)
2. Uncomment the line below it that lists all cluster members (currently commented: `# wsrep_cluster_address=gcomm://galera1,galera2,galera3`)

Then restart the node:

```bash
docker compose restart galera1
```

After restart, `galera1` will join the existing cluster instead of trying to bootstrap. You can change it back to `gcomm://` if you want to use it for future full-cluster bootstraps.

**Why the empty `gcomm://` exists:** The empty address list is needed for the *first* bootstrap when no cluster exists. With a full address list, Galera tries to connect to peers first; if they don't exist, it enters NON_PRIM state and won't bootstrap automatically. The empty `gcomm://` tells it to bootstrap immediately when the datadir is empty.

### Backups and restores

Why: You still need point-in-time backups; Galera just changes where you run them and how restores re-seed the cluster.

Steps:

1. Hot backup from a non-writer node:  
   `docker compose exec galera2 mariabackup --backup --target-dir=/tmp/backup`.[^2]  
   Copy it out (`docker cp`) and run `mariabackup --prepare` so the files are consistent.
2. Restore by stopping all nodes, placing the prepared backup on a single node (e.g., `galera1`), bootstrapping it, and letting the others rejoin via IST/SST (incremental vs snapshot transfer; see the [terminology cheat sheet](#galera-terminology-cheat-sheet)). That mirrors the documented "restore one, let others sync" pattern.[^2]
3. Logical dumps remain valid (`mariadb-dump --single-transaction`), but physical backups preserve GTID metadata required for clean SST handshakes.

### Schema changes

Why: Schema changes (DDL - Data Definition Language statements like `CREATE TABLE`, `ALTER TABLE`, `DROP INDEX`) in Galera can block the entire cluster when using the default Total Order Isolation (TOI) method. TOI ensures all nodes apply the schema change simultaneously, but this means the entire cluster is paused during the operation. You need a plan before the change window.

Steps:

1. For quick changes, run the DDL as usual and monitor `wsrep_flow_control_paused` to ensure the cluster is not throttled (flow-control is explained in the [terminology cheat sheet](#galera-terminology-cheat-sheet)).  
2. For heavyweight migrations (large table alterations, index rebuilds, etc.), temporarily switch one node to Rolling Schema Upgrade (RSU) instead of the default Total Order Isolation (TOI). RSU isolates a single node for the change, allowing other nodes to continue serving traffic:

   ```bash
   docker compose exec galera1 mariadb \
     -uroot -p"$MARIADB_ROOT_PASSWORD" \
     -e "SET GLOBAL wsrep_OSU_method='RSU'; ALTER TABLE ...; SET GLOBAL wsrep_OSU_method='TOI';"
   ```

   **Important:** Only the node running RSU accepts writes during the change, so keep the change window tight and ensure your application can handle the temporary write restriction. After the change completes, switch back to TOI to restore normal cluster-wide DDL behavior.[^2]

### Monitoring and flow control

Why: Galera's consensus layer exposes extra status variables; treat them as first-class SLO signals.

Steps:

1. Run `SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size';` and `'wsrep_local_state_comment';` to prove quorum and node state (`Synced`, `Donor`, `Joining`—all defined in the [terminology cheat sheet](#galera-terminology-cheat-sheet)).  
2. Watch `'wsrep_flow_control_paused';` values near 0.0 are healthy; 0.2 or higher indicates a performance bottleneck (a slow node is causing the cluster to pause replication).[^11]  
3. Tail `/var/log/mysql/galera*.err` for `Flow control paused` or `Non-Primary view` entries so you catch congestion or split-brain conditions early.

### WAN clustering

Why: Synchronous replication works over WAN networks. The delay is proportional to network round-trip time (RTT) and affects commit operations - reads execute instantly from the local node, but writes must wait for commit acknowledgment from all nodes.[^9]

**How WAN clustering works:**

Unlike traditional async replication where writes return immediately and replicas catch up later, Galera waits for acknowledgment from every node before the transaction commits. The user experience:

1. **Reads execute instantly** from the local node - no WAN latency, no waiting
2. **Write operations execute locally** on the nearest node - the SQL runs fast
3. **The commit waits** for WAN round-trips to all nodes - this is what the user experiences

If you have nodes in New York, London, and Tokyo, a write transaction:

- Executes the SQL locally in New York (fast, ~1ms)
- Waits for commit acknowledgment from London (~70ms RTT) and Tokyo (~140ms RTT)
- Returns success to the application only after all nodes acknowledge (total ~200ms+)

So yes, the user does wait for the WAN round-trips - the commit latency is part of every write transaction. The benefit is that reads are instant (no WAN latency) and the SQL execution itself is fast (only the commit coordination adds latency). For read-heavy workloads or applications where occasional slower writes are acceptable, this trade-off can work. However, high write throughput applications will feel the commit latency on every transaction.[^9]

**When WAN clustering makes sense:**

- **Latency eraser:** With nodes located close to clients, read operations are instant and write SQL execution is fast. The RTT delay affects commit time (users do wait for this), but this can be acceptable for read-heavy workloads where users experience fast browsing and occasional slower writes are tolerable.[^9]

- **Disaster recovery:** One data center can be passive, only receiving replication events without processing client transactions. The remote data center stays up to date at all times with no data loss. During recovery, the spare site is nominated as primary and applications continue with minimal failover delay.[^9]

- **Read-heavy workloads with geographic distribution:** Client applications can be directed to the topologically closest node, reducing network latency for read operations. Users get fast reads from their local node, and occasional writes pay the commit latency penalty.[^12]

**When to avoid WAN clustering:**

- High write throughput applications (every write waits for WAN round-trips)
- Latency-sensitive workloads (user-facing transactions that must feel instant)
- Unreliable WAN links (packet loss causes flow control pauses and timeouts)

**Configuration for WAN deployments:**

1. **Quorum requirements:** You need an odd number of nodes and an odd number of locations to maintain quorum. A typical setup is three data centers with one or more nodes in each.[^12]

2. **Network latency:** The round-trip time between the most distant nodes sets the baseline for transaction commit latency. Keep RTT under a few milliseconds if possible; above 5-10ms, writes will feel sluggish because every transaction waits for consensus.[^2] For true multi-site active-active, you need dedicated low-latency links (not commodity internet).

3. **Network stability:** The WAN link must be stable and reliable. Frequent network partitions can lead to nodes being evicted from the cluster, impacting stability. Monitor `wsrep_local_recv_queue_avg` to detect nodes struggling to keep up (high or increasing values suggest network issues or node performance problems).

4. **Use segmentation to optimize traffic patterns:**

   ```ini
   # Nodes in data center A
   wsrep_provider_options = "gmcast.segment = 0; ..."
   
   # Nodes in data center B  
   wsrep_provider_options = "gmcast.segment = 1; ..."
   ```

   Group nodes with `gmcast.segment` so intra-site traffic stays local (terminology recap in the [cheat sheet](#galera-terminology-cheat-sheet)). This reduces cross-WAN chatter for operations that don't require global consensus.[^12]

5. **Increase timeouts to tolerate WAN characteristics:**

   ```ini
   wsrep_provider_options = "evs.keepalive_period = PT3S; evs.suspect_timeout = PT30S; evs.inactive_timeout = PT1M; evs.install_timeout = PT1M"
   ```

   These parameters can tolerate 30-second connectivity outages. **Important:** All `wsrep_provider_options` settings must be specified on a single line; if you have multiple instances, only the last one is used. Set `evs.suspect_timeout` as high as possible to avoid partitions (which cause state transfers and impact performance). You must set `evs.inactive_timeout` higher than `evs.suspect_timeout`, and `evs.install_timeout` higher than `evs.inactive_timeout`.[^13]

6. **Add a Galera Arbitrator (`garbd`)** if you only have two DB nodes per site to avoid split-brain scenarios during network partitions.

### Configuration deep dive

Why: Most "normal" MariaDB knobs still apply; these are the Galera-specific ones to carry into production.

1. `wsrep_cluster_address=gcomm://` on node 1 is a lab shortcut so an empty datadir bootstraps automatically. In production list every peer FQDN so the node rejoins the existing component instead. **Important:** If you restart `galera1` while other nodes are running, you must temporarily change this to list all members (see [Restarting the bootstrap node](#bring-a-node-back) for details).[^6]  
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
[^11]: [MariaDB Galera Cluster - Flow Control](https://mariadb.com/docs/galera-cluster/galera-management/performance-tuning/flow-control-in-galera-cluster)
[^12]: [MariaDB Galera Cluster Deployment Variants - WAN Cluster](https://mariadb.com/docs/galera-cluster/galera-architecture/galera-cluster-deployment-variants#wide-area-network-wan-cluster-multi-data-center)
[^13]: [Galera Cluster - WAN Replication](https://galeracluster.com/library/kb/wan-replication.html)
[^14]: [MariaDB Galera Cluster - Monitoring](https://mariadb.com/docs/galera-cluster/high-availability/monitoring-mariadb-galera-cluster), [Recovering a Primary Component](https://mariadb.com/docs/galera-cluster/high-availability/recovering-a-primary-component)
[^15]: [MariaDB Galera Cluster - Recovering a Primary Component](https://mariadb.com/docs/galera-cluster/high-availability/recovering-a-primary-component), [Galera Cluster Documentation - Non-Primary State](https://galeracluster.com/library/documentation/index.html)

---

## Clean Up

When you are done experimenting:

```bash
docker compose down -v
```

This removes containers and volumes so you can re-run the bootstrap from scratch.
