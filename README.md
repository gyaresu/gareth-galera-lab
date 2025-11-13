# Passbolt On Galera: A Hands-On Lab

Running passbolt against a three-node MariaDB Galera cluster is an easy way to explore high availability foundations before deploying to production. This lab walk-through uses the `galera-tls-passbolt` repository to spin up a full stack locally, exercise replication, and confirm passbolt operates over mutual TLS.

---

## What You’ll Build

- Three MariaDB 11.5 nodes in a Galera cluster with TLS-enabled replication and client auth
- Valkey providing Redis-compatible caching for Passbolt sessions and queues (Valkey is the community-maintained fork of Redis 7, API-compatible with the upstream project; this lab pins `valkey/valkey:8.1.4-alpine`, the 2025‑10‑21 release)
- Passbolt Community Edition pointed at the cluster via HTTPS

We will generate certificates, launch the stack with Docker Compose, validate the database topology, and finish by logging into Passbolt.

---

## Prerequisites

- Docker Compose v2
- GNU `bash` ≥ 4 (macOS ships with 3.2; install a newer version, e.g. Homebrew’s `/opt/homebrew/bin/bash`)
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
> **Tip:** With `.env` ready, you can bring up the full stack in one go with `./scripts/start-lab.sh --reset`. The script handles certificate generation, Galera bootstrap, Valkey/Passbolt startup, and the smoke tests covered below.

---

## When Galera Is (and Isn’t) the Default

For a single Passbolt instance or a proof-of-concept, a standalone MariaDB server is still the lowest-effort option—simpler backups, fewer moving parts, and lower resource overhead. Galera shines when you need synchronous failover, zero data loss guarantees, or rolling maintenance with continuous service. The MariaDB usage guide calls out these trade-offs explicitly: multi-primary clusters eliminate replication lag but add operational complexity, so treat Galera as the “step up” once availability requirements outgrow a single node.[^2]

---

## Step 0 – Generate Demo GPG Keys (Optional but Handy)

The repo now ships with a helper that mints ECC keys for demo users. By default it creates material for `ada@passbolt.com` (passphrase equals the email), but you can pass additional `email:Full Name` pairs if you need more identities.

```bash
./scripts/generate-demo-gpg.sh
# or e.g. ./scripts/generate-demo-gpg.sh \
#   "ada@passbolt.com:Ada passbolt" \
#   "betty@passbolt.com:Betty passbolt"
```

Outputs land under `keys/gpg/`, producing `<email>.key` and `<email>.pub` files. When the Passbolt web installer asks for Ada’s private key, use `keys/gpg/ada@passbolt.com.key` with passphrase `ada@passbolt.com`.

---

## Step 1 – Generate Certificates

The `scripts/generate-certs.sh` helper issues a root CA, server certs for each Galera node, and a mutual TLS client cert for Passbolt. Because the script uses associative arrays, invoke it with the modern bash binary:

```bash
/opt/homebrew/bin/bash ./scripts/generate-certs.sh
```

Outputs land in `certs/` and are mounted automatically by Compose.

> **Gotcha:** Running the script with macOS’ default bash 3.2 triggers `unbound variable` errors. Always call the Homebrew bash (or any 4.x/5.x build).

---

## Step 2 – Bootstrap the Galera Cluster

Bring up the first node on its own so it can form a primary component:

```bash
docker compose up -d galera1
docker compose logs --no-color galera1
```

Confirm Galera reports `Primary`:

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

The stock Compose file ships with `mysqladmin` health checks, but the MariaDB 11.5 image only exposes `mariadb-admin`. Additionally, TLS hostname verification fails because the container’s hostname is not `galera1.local`. Updating the health check to use the Unix socket keeps the dependency graph happy:

```yaml
healthcheck:
  test: ["CMD-SHELL", "mariadb-admin ping -uroot -p\"$${MARIADB_ROOT_PASSWORD}\" --socket=/run/mysqld/mysqld.sock"]
```

After tweaking the YAML, recreate the services (`docker compose up -d galera1 galera2 galera3`) to see them transition to `healthy`.

### Replication & TLS Validation

Write a row through node 1 and read it back via node 2:

```bash
docker compose exec galera1 mariadb \
  -u"$DATASOURCES_DEFAULT_USERNAME" -p"$DATASOURCES_DEFAULT_PASSWORD" "$DATASOURCES_DEFAULT_DATABASE" \
  -e "CREATE TABLE galera_probe (id INT PRIMARY KEY AUTO_INCREMENT, note VARCHAR(255)); \
      INSERT INTO galera_probe (note) VALUES ('bootstrapped via galera1');"

docker compose exec galera2 mariadb \
  -u"$DATASOURCES_DEFAULT_USERNAME" -p"$DATASOURCES_DEFAULT_PASSWORD" "$DATASOURCES_DEFAULT_DATABASE" \
  -e "SELECT * FROM galera_probe;"
```

Check that connections negotiate TLS:

```bash
docker compose exec galera1 mariadb \
  -u"$DATASOURCES_DEFAULT_USERNAME" -p"$DATASOURCES_DEFAULT_PASSWORD" "$DATASOURCES_DEFAULT_DATABASE" \
  -e "SHOW STATUS LIKE 'Ssl_cipher';"
```

You should see `TLS_AES_256_GCM_SHA384`.

### TLS Everywhere

- **Galera replication** uses the certificates mounted into each node (`server-cert.pem`, `server-key.pem`, `ca.pem`) via `wsrep_provider_options`, so node-to-node state transfers run over TLS.
- **passbolt client traffic** is forced over TLS by `config/mariadb/init/02-enforce-ssl.sql`, and the environment variables point passbolt at `/etc/passbolt/db-*.{crt,key}`. The cipher check above confirms the connection negotiates TLS successfully.  
- **Account policy** mirrors MariaDB’s recommendation to require TLS on sensitive users: `ALTER USER 'passbolt'@'%' REQUIRE SSL;` ensures credentials are never sent in cleartext, aligning with the server’s TLS-intention guidance.[^3]  
- **Server capability** can be confirmed with `SHOW GLOBAL VARIABLES LIKE 'have_ssl';`—a `YES` value indicates the engine loaded TLS support, matching the secure-connections checklist from MariaDB.[^4]

---

## Step 3 – Start Valkey and Passbolt

> **Why no ProxySQL?**  
> ProxySQL’s Docker image currently ships without a full certificate chain on its frontend listener, which causes strict clients to reject the TLS handshake (see [issue #3788](https://github.com/sysown/proxysql/issues/3788)). Rather than keep a broken proxy in the loop, this demo connects Passbolt directly to the Galera nodes. You can reintroduce HAProxy/ProxySQL later if you need health-aware load balancing.

With the database tier stable, launch the remaining services:

```bash
docker compose up -d valkey passbolt
```

Map Passbolt’s internal HTTPS listener to the host for convenience (already committed to `docker-compose.yaml`):

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

Repeat the process to flip back to `galera1` once you’re done testing.

---

## Troubleshooting Notes

- **Bash 3 vs 5:** Using macOS’ default shell will fail the certificate script. Install and call Bash 5 explicitly.
- **MariaDB Health Checks:** Replace `mysqladmin` with `mariadb-admin` and use the socket to bypass TLS hostname validation.
- **Passbolt Cache Engine:** A mis-escaped environment value (`Cake\\Cache\\Engine\\RedisEngine`) causes the application bootstrap to throw.
- **Port Exposure:** Exposing Passbolt on `443` simplifies local navigation; production setups usually sit behind a reverse proxy or load balancer.
- **Smoke tests:** Run `./scripts/check-stack.sh` any time to re-validate Galera status and the Passbolt health check without repeating the full bring-up sequence.

---

## Operating & Managing the Cluster

The goal is to give a MariaDB administrator familiar tasks (restart, backup, restore, migrate) and show the Galera-specific twists. Every walkthrough below mirrors the MariaDB Galera documentation so you can apply the same flow to physical or cloud hosts.[^2]

### Bootstrap and recovery

Why: After a full outage you must bring only the freshest node online first; otherwise the cluster may form diverging primary components.

Steps:

1. Inspect `grastate.dat` on each node to find the highest `seqno` or a `safe_to_bootstrap=1` flag:  
   `docker compose exec galera1 cat /var/lib/mysql/grastate.dat`
2. If the best candidate shows `seqno = -1`, recover the real position:  
   `docker compose exec galera1 sh -c 'mariadb --execute "SET GLOBAL wsrep_on=OFF"; /usr/sbin/mariadbd --wsrep-recover --user=mysql'`.[^7]
3. On that node only, bootstrap the cluster: `docker compose exec galera1 galera_new_cluster`.  
   Bring the remaining nodes up normally; expect IST when their GCache is still hot, SST otherwise.[^2][^6]

### Bring a node back

Why: Daily maintenance still happens per node; Galera adds donor/recipient behaviour you should confirm.

Steps:

1. For routine restarts: `docker compose restart galera2`. Galera keeps the node in `Synced`.  
2. After a crash, stop the container, review `/var/lib/mysql/grastate.dat`, and start it again. If corruption is obvious, wipe the datadir (in production you would re-image the server) and let SST rebuild it.  
3. When the cluster lost quorum, bootstrap a single node as above, verify `wsrep_cluster_status=Primary`, then start peers sequentially to regain size without split-brain.[^2]

### Backups and restores

Why: You still need point-in-time backups; Galera just changes where you run them and how restores re-seed the cluster.

Steps:

1. Hot backup from a non-writer node:  
   `docker compose exec galera2 mariabackup --backup --target-dir=/tmp/backup`.[^2]  
   Copy it out (`docker cp`) and run `mariabackup --prepare` so the files are consistent.
2. Restore by stopping all nodes, placing the prepared backup on a single node (e.g., `galera1`), bootstrapping it, and letting the others rejoin via IST/SST. That mirrors the documented “restore one, let others sync” pattern.[^2]
3. Logical dumps remain valid (`mariadb-dump --single-transaction`), but physical backups preserve GTID metadata required for clean SST handshakes.

### Schema changes

Why: Large DDL in Galera blocks the cluster via Total Order Isolation; you need a plan before the change window.

Steps:

1. For quick changes, run the DDL as usual and monitor `wsrep_flow_control_paused` to ensure the cluster is not throttled.  
2. For heavyweight migrations, temporarily switch one node to Rolling Schema Upgrade:  
   `docker compose exec galera1 mariadb --execute "SET GLOBAL wsrep_OSU_method='RSU'; ALTER TABLE ...; SET GLOBAL wsrep_OSU_method='TOI';"`.[^2]  
   Only that node accepts writes during RSU, so keep the change window tight.

### Monitoring and flow control

Why: Galera’s consensus layer exposes extra status variables—treat them as first-class SLO signals.

Steps:

1. Run `SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size';` and `'wsrep_local_state_comment';` to prove quorum and node state (`Synced`, `Donor`, `Joining`).  
2. Watch `'wsrep_flow_control_paused';`—anything sustained above ~0.5 means replicas are slowing the writer.[^2]  
3. Tail `/var/log/mysql/galera*.err` for `Flow control paused` or `Non-Primary view` entries so you catch congestion or split-brain conditions early.

### Multi-site and latency

Why: Standard MariaDB replication tolerates latency; Galera requires tight RTT and extra quorum tuning.

Steps:

1. Keep RTT under a few milliseconds; above 5–10 ms writes will feel sluggish because every transaction waits for consensus.[^2]  
2. Group nodes with `gmcast.segment` so intra-site traffic stays local.  
3. Increase `evs.suspect_timeout` / `evs.inactive_timeout` to match WAN latency and add a Galera Arbitrator (`garbd`) if you only have two DB nodes per site.

### Configuration deep dive

Why: Most “normal” MariaDB knobs still apply; these are the Galera-specific ones to carry into production.

1. `wsrep_cluster_address=gcomm://` on node 1 is a lab shortcut so an empty datadir bootstraps automatically. In production list every peer FQDN so the node rejoins the existing component instead.[^6]  
2. TLS directives (`socket.ssl_ca`, `socket.ssl_cert`, `socket.ssl_key`) and `require_secure_transport=ON` keep both replication and client traffic encrypted—match them to your site-issued certificates.[^5]  
3. The repo drops its overrides into `/etc/mysql/mariadb.conf.d/z-custom-my.cnf`, following MariaDB’s advice to keep vendor configs untouched for easier upgrades.[^5]

### Next steps

1. Automate the Passbolt GPG fingerprint/JWT provisioning immediately after bootstrap so the healthcheck is clean.  
2. Revisit ProxySQL or HAProxy once the TLS frontend issue mentioned earlier is resolved; either proxy can front the Galera writer hostgroup for the application.  
3. Schedule recurring `mariabackup` exports to external storage and rehearse the restore flow so the wider Passbolt HA pattern is battle-tested.[^1]

[^1]: [How to Set-Up a Highly-Available Passbolt Environment](https://www.passbolt.com/blog/how-to-set-up-a-highly-available-passbolt-environment)
[^2]: [MariaDB Galera Cluster Usage Guide](https://mariadb.com/docs/galera-cluster/readme/mariadb-galera-cluster-usage-guide)
[^3]: [MariaDB Server – ALTER USER TLS Options](https://mariadb.com/docs/server/reference/sql-statements/account-management-sql-statements/alter-user/#tls-options)
[^4]: [MariaDB Server – Secure Connections Overview](https://mariadb.com/docs/server/security/securing-mariadb/encryption/data-in-transit-encryption/secure-connections-overview)
[^5]: [MariaDB Server – Enabling TLS on MariaDB Server](https://mariadb.com/docs/server/security/securing-mariadb/encryption/data-in-transit-encryption/data-in-transit-encryption-enabling-tls-on-mariadb-server)
[^6]: [MariaDB Galera Cluster Guide – Configure `galera.cnf`](https://mariadb.com/docs/galera-cluster/galera-cluster-quickstart-guides/mariadb-galera-cluster-guide/#id-4.-configure-galera-cluster-galera.cnf-on-each-node)
[^7]: [MariaDB Galera Cluster System Variables – `wsrep_recover`](https://mariadb.com/docs/galera-cluster/reference/galera-cluster-system-variables/#wsrep_recover)

---

## Clean Up

When you are done experimenting:

```bash
docker compose down -v
```

This removes containers and volumes so you can re-run the bootstrap from scratch.
