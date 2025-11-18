# passbolt with MariaDB Galera Cluster using Mutual TLS (mTLS) authentication

![Three-node Galera cluster with passbolt](galera_passbolt.jpeg)

I've been `computering` a long time but I was new to Galera so I build a demo cluster. It made me so happy that I wrote this blog post.

The code for this lab is available on github.

> Everything in this repo is for experimental use only.
>
> 5 minutes after it's published it will change in arbitrary and unpredictable ways.
>
> When your program breaks, you get to keep both pieces.

![link](link.gif) 
**Link**: [https://github.com/gyaresu/gareth-galera-lab](https://github.com/gyaresu/gareth-galera-lab)

I created this demonstration lab to share why I think MariaDB Galera Cluster should be your preferred database solution with passbolt when you're hosting more than the family password server.

If you're looking for a complete walkthrough of setting up a highly available passbolt environment with Galera, my colleague Louis has you covered in his blog post on [How to Set-Up a Highly-Available Passbolt Environment](https://www.passbolt.com/blog/how-to-set-up-a-highly-available-passbolt-environment).

This post goes deeper into configuring Galera clusters with mutual TLS (mTLS) authentication, including a complete lab you can run locally. The mTLS configuration makes for secure, scaleable, and manageable, clusters that work across subnets, data centers, and WAN links without complex firewall rules.

This lab uses docker but it directly translates to hosting your databases on separate host machines in separate physical locations. Geographically distributed is actually how I would recommend you plan your cluster.

Being in Australia, we're very aware of the 250ms round trip to servers hosted in the US/EU, so you'll need to consider the speed of light in your hosting plan. One of the great benefits of Galera is multi-master writes: ["Typically, a node executes a transaction fully and replicates the complete write-set to other nodes at COMMIT time."](https://mariadb.com/docs/galera-cluster/galera-management/performance-tuning/using-streaming-replication-for-large-transactions#large-data-transactions) This means writes execute locally (fast), and only the commit waits for replication to complete across the cluster.

## How does a robust and and easy to manage database cluster benefit passbolt at scale?

When you're running passbolt for hundreds of users, your database becomes a critical dependency. A single database server means:

- **No maintenance window flexibility**: Database updates require downtime
- **Single point of failure**: Hardware failure takes the entire service offline
- **Replication lag concerns**: Async replication means the DR site is always behind
- **Network security complexity**: Firewall rules get unwieldy when nodes span multiple locations

Galera's synchronous replication solves the first three problems: zero data loss, zero replication lag, and rolling maintenance without downtime. For example, you can perform [rolling upgrades](https://mariadb.com/docs/galera-cluster/galera-management/upgrading-galera-cluster/upgrading-from-mariadb-10-6-to-mariadb-10-11-with-galeracluster) from MariaDB 10.6 to 10.11 (or any major version) by upgrading nodes one at a time while the cluster remains operational. No scheduled downtime, no service interruption. The fourth problem is network security complexity, and that's where mutual TLS becomes essential.

## The mTLS Advantage

Standard TLS encrypts traffic, but mutual TLS authenticates both sides. Instead of just the client verifying the server certificate, both sides present certificates. This means:

- **Certificates authenticate peers, not IP addresses**: You can move nodes between subnets without rewriting firewall rules
- **Network topology becomes flexible**: Nodes can be in different racks, buildings, or data centers
- **Security scales with infrastructure**: Adding a node means issuing a certificate, not managing complex firewall rules

For passbolt deployments, this is especially valuable when you need to:
- Distribute nodes across data centers for disaster recovery
- Perform rolling maintenance without service interruption
- Scale the database tier without network reconfiguration

Of course, this all depends on DNS working correctly. Nodes resolve each other by hostname, and certificate SANs need to match those hostnames. When something breaks, **it's always DNS™**. But at least with mTLS, you know the certificate validation will tell you if DNS is pointing to the wrong place.

## What You'll Build

This lab sets up:

- Three MariaDB 11.8 nodes in a Galera cluster with TLS-encrypted replication
- Mutual TLS authentication between passbolt and the database
- Valkey (Redis-compatible) for session storage and caching
- Production-ready configurations that work on physical servers

The Docker setup is just a convenient way to test locally. All the configurations translate directly to bare metal or virtual machines.

## Certificate Architecture

The lab generates three types of certificates that work together to enable mutual TLS:

### 1. Root CA Certificate (`rootCA.crt` and `rootCA.key`)

**Purpose:** The Certificate Authority that signs all other certificates in the cluster.

**What it does:**
- Creates a trust chain: all nodes trust certificates signed by this CA
- Valid for 10 years (3650 days)
- Self-signed (it signs itself)

**Where it's used:**
- Mounted on all Galera nodes as `/etc/mysql/ssl/ca.pem` to verify peer certificates
- Mounted on passbolt as `/etc/passbolt/db-ca.crt` to verify database server certificates

**Why it matters:** Instead of trusting individual certificates, everyone trusts the CA. This simplifies management. Add a new node by issuing a certificate signed by the same CA.

### 2. Server Certificates (one per Galera node: `galera1.crt`, `galera2.crt`, `galera3.crt`)

**Purpose:** Each Galera node has its own server certificate used for two purposes:
1. **Galera replication (node-to-node mTLS)**
2. **Client connections (passbolt-to-database TLS)**

**What it contains:**
- **Common Name (CN):** The `.local` alias (e.g., `galera1.local`)
- **Subject Alternative Names (SANs):**
  - `DNS.1 = galera1` (short hostname)
  - `DNS.2 = galera1.local` (DNS alias)
- **Extended Key Usage:** `serverAuth, clientAuth` (can act as both server and client)

**Where it's used:**

**For Galera replication (mTLS):**
```ini
wsrep_provider_options="socket.ssl_cert=/etc/mysql/ssl/server-cert.pem;\
socket.ssl_key=/etc/mysql/ssl/server-key.pem;\
socket.ssl_ca=/etc/mysql/ssl/ca.pem"
```
- Each node presents its own certificate when connecting to peers
- Each node verifies peer certificates using the CA
- This is mutual TLS: both sides authenticate each other

**For client connections (TLS):**
```ini
ssl-cert=/etc/mysql/ssl/server-cert.pem
ssl-key=/etc/mysql/ssl/server-key.pem
ssl-ca=/etc/mysql/ssl/ca.pem
```
- MariaDB presents this certificate to clients (like passbolt)
- Clients verify it using the CA certificate

**Why SANs matter:** The certificate validates whether you connect using `galera1` or `galera1.local`, because both are in the SANs. This flexibility is crucial when nodes might be referenced by different names.

### 3. Client Certificate (`passbolt-db-client.crt` and `passbolt-db-client.key`)

**Purpose:** Allows passbolt to authenticate to the database using mTLS.

**What it contains:**
- **Common Name (CN):** `passbolt-db-client.local` (just an identifier, doesn't need to resolve to a hostname)
- **Subject Alternative Names:** Same as CN
- **Extended Key Usage:** `serverAuth, clientAuth`

**Note:** The CN for client certificates is just an identifier. MariaDB doesn't validate it against a hostname. It only verifies the certificate is signed by the trusted CA and has the correct key usage. The CN could be anything (e.g., `passbolt-client`, `db-app-cert`). `passbolt-db-client.local` is just a descriptive name.

**Where it's used:**
```yaml
DATASOURCES_DEFAULT_SSL_CA: /etc/passbolt/db-ca.crt
DATASOURCES_DEFAULT_SSL_CERT: /etc/passbolt/db-client.crt
DATASOURCES_DEFAULT_SSL_KEY: /etc/passbolt/db-client.key
```

**How it works:**
1. passbolt connects to MariaDB
2. MariaDB presents its server certificate (e.g., `galera1.crt`)
3. passbolt verifies it using the CA (`db-ca.crt`)
4. passbolt presents its client certificate (`db-client.crt`)
5. MariaDB verifies it using the CA and checks the user requires SSL:
   ```sql
   ALTER USER 'passbolt'@'%' REQUIRE SSL;
   ```

**Why it matters:** Only passbolt (with this certificate) can connect. Even with the password, a connection without the client certificate is rejected.

### The Two mTLS Flows

**Flow 1: Galera Node-to-Node Replication**

```
galera1                          galera2
   |                                |
   |---[presents galera1.crt]----->|
   |<--[presents galera2.crt]------|
   |                                |
   |---[verifies with CA]---------->|
   |<--[verifies with CA]----------|
```

Both nodes:
- Present their server certificates
- Verify each other using the CA
- Encrypt replication traffic

**Flow 2: passbolt-to-Database Connection**

```
passbolt                         galera1
   |                                |
   |---[connects]------------------>|
   |<--[presents galera1.crt]-------|
   |---[verifies with CA]---------->|
   |---[presents db-client.crt]--->|
   |<--[verifies with CA]-----------|
```

Both sides:
- MariaDB presents its server certificate
- passbolt verifies it with the CA
- passbolt presents its client certificate
- MariaDB verifies it with the CA

### Why This Architecture?

1. **Single CA:** One root CA signs everything, simplifying trust management
2. **Dual-purpose server certs:** Each node's certificate works for both replication and client connections
3. **SANs:** Certificates support multiple hostname formats (short name and DNS alias)
4. **Mutual authentication:** Both replication and application connections use mTLS, not just encryption

This setup enables secure distributed topologies. Nodes authenticate via certificates, not IP addresses, so you can move nodes between networks as long as DNS resolves and certificates are valid.

## Quick Start

1. **Clone the repository and set up environment variables:**

   ```bash
   git clone <repo-url>
   cd gareth-galera-lab
   cp env.example .env
   # Edit .env with your passwords and passbolt admin details
   ```

   **Note:** Commands below that use environment variables (like `$MARIADB_ROOT_PASSWORD`) require sourcing `.env` first:
   ```bash
   source .env
   ```
   Commands running inside Docker containers already have access to these variables.

2. **Generate certificates:**

   ```bash
   /opt/homebrew/bin/bash ./scripts/generate-certs.sh
   ```

   The script creates a root CA, server certificates for each Galera node, and a client certificate for passbolt.

3. **Bootstrap the cluster:**

   ```bash
   ./scripts/start-lab.sh --reset
   ```

   This handles certificate generation (if needed), cluster bootstrap, and service startup. The script also automatically registers the passbolt admin user (default: `ada@passbolt.com`) and prints a setup link in the terminal output. The link looks like:
   
   ```
   https://passbolt.local/setup/start/07bc558e-c697-43d5-b5ff-df670a46e684/d5762e80-09cf-40aa-a017-f40c4ba69559
   ```
   
   Copy that link and open it in your browser to complete the user setup (you'll need to trust the self-signed certificate when prompted).

4. **Complete user setup in browser:**

   Open the setup link from the terminal output in your browser. You'll need to import your GPG key (use `keys/gpg/ada@passbolt.com.key` with passphrase `ada@passbolt.com` if you generated demo keys) and complete the passbolt setup wizard.

## Verification Checklist

After bringing up the cluster, verify everything is working. If running commands from your host (not inside containers), remember to `source .env` first (see Quick Start above).

**Cluster health:**
```bash
# All nodes should show Primary status
docker compose exec galera1 mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" \
  -e "SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_status', 'wsrep_cluster_size', 'wsrep_incoming_addresses');"
```

Example output:

| Variable_name            | Value                                    |
|--------------------------|------------------------------------------|
| wsrep_incoming_addresses | galera1.local:0,galera2.local:0,galera3.local:0 |
| wsrep_cluster_size       | 3                                        |
| wsrep_cluster_status     | Primary                                  |

**Replication working:**
```bash
# Write to node 1
docker compose exec galera1 mariadb \
  -u"$DATASOURCES_DEFAULT_USERNAME" -p"$DATASOURCES_DEFAULT_PASSWORD" \
  "$DATASOURCES_DEFAULT_DATABASE" \
  -e "CREATE TABLE IF NOT EXISTS test_replication (id INT PRIMARY KEY AUTO_INCREMENT, note VARCHAR(255)); \
      INSERT INTO test_replication (note) VALUES ('test from galera1');"

# Read from node 2
docker compose exec galera2 mariadb \
  -u"$DATASOURCES_DEFAULT_USERNAME" -p"$DATASOURCES_DEFAULT_PASSWORD" \
  "$DATASOURCES_DEFAULT_DATABASE" \
  -e "SELECT * FROM test_replication;"
```

Example output:

| id | note              |
|----|-------------------|
|  1 | test from galera1 |

The row appears immediately on node 2, confirming synchronous replication.

**TLS encryption:**
```bash
# Check TLS cipher on client connections
docker compose exec galera1 mariadb \
  -u"$DATASOURCES_DEFAULT_USERNAME" -p"$DATASOURCES_DEFAULT_PASSWORD" \
  -e "SHOW STATUS LIKE 'Ssl_cipher';"
```

Example output:

| Variable_name | Value             |
|---------------|-------------------|
| Ssl_cipher    | TLS_AES_256_GCM_SHA384 |

A non-empty value confirms TLS is active.

**passbolt connectivity:**
```bash
docker compose exec passbolt \
  su -s /bin/bash -c "source /etc/environment >/dev/null 2>&1 || true; /usr/share/php/passbolt/bin/cake passbolt healthcheck" www-data
```

The database connection check should pass (you may see warnings about self-signed certificates, which is expected in the lab).

## How It Works

### Galera Replication (Node-to-Node)

To secure replication traffic between nodes, we configure TLS in `galera.cnf` using `wsrep_provider_options` as described in [MariaDB's security documentation](https://mariadb.com/docs/galera-cluster/galera-security/securing-communications-in-galera-cluster):

```ini
# TLS for Galera replication traffic (port 4567)
wsrep_provider_options="socket.ssl_cert=/etc/mysql/ssl/server-cert.pem;\
socket.ssl_key=/etc/mysql/ssl/server-key.pem;\
socket.ssl_ca=/etc/mysql/ssl/ca.pem"
```

We also set the regular MariaDB TLS variables for client connections (port 3306):

```ini
# TLS for client connections (port 3306)
ssl-ca=/etc/mysql/ssl/ca.pem
ssl-cert=/etc/mysql/ssl/server-cert.pem
ssl-key=/etc/mysql/ssl/server-key.pem
```

Nodes connect to each other using DNS names (`.local` aliases in this lab, FQDNs in production) rather than IP addresses. The `wsrep_cluster_address` configuration lists all cluster members:

```ini
wsrep_cluster_address=gcomm://galera1.local,galera2.local,galera3.local
wsrep_node_address=galera1.local:4567
```

Galera uses three ports for cluster operations:
- **4567**: Galera replication traffic (write-set replication between nodes) - **uses mTLS** via `wsrep_provider_options` socket.ssl settings
- **3306**: Standard MariaDB port for client connections - **uses mTLS** with client certificates
- **4444**: State Snapshot Transfer (SST) - used for catastrophic recovery scenarios. SST encryption is out of scope for this lab

When nodes replicate over port 4567, they:
1. Resolve peer hostnames via DNS (Docker network aliases in the lab, DNS in production)
2. Present their server certificates
3. Verify peer certificates using the CA

The certificates include Subject Alternative Names (SANs) that match both the short hostname (`galera1`) and the DNS alias (`galera1.local`), so certificate validation succeeds regardless of which name is used. This is mTLS for replication traffic: both sides authenticate each other using certificates, not IP addresses.

**State transfers (IST vs SST)**: When a node joins or rejoins the cluster, Galera uses one of two methods to synchronize data:
- **IST (Incremental State Transfer)**: The preferred method. If the node was offline briefly and Galera's GCache still contains the missing transactions, it uses IST to replay only the missing write-sets (fast, incremental). This is the normal case for nodes that were briefly offline. IST uses the same replication traffic (port 4567) that's already encrypted with mTLS. Larger GCache size (`gcache.size` in `wsrep_provider_options`) allows nodes to be offline longer before falling back to SST—this lab sets 512M, but production deployments should size based on write rate and desired offline tolerance.
- **SST (State Snapshot Transfer)**: A full database copy (slower, resource-intensive). SST happens when adding new nodes for the first time, or during catastrophic recovery scenarios when a node has been offline so long that GCache no longer has the missing transactions. SST encryption is out of scope for this lab, which focuses on demonstrating mTLS for replication and client connections. For production, you can configure rsync SST to use SSH for encryption, though be aware that for very large databases (hundreds of GB or more), SST transfers can take hours even over fast networks.

**All normal node-to-node traffic uses mTLS**: Replication traffic on port 4567 uses `wsrep_provider_options` for mTLS, and client connections on port 3306 use client certificates. This ensures that all routine cluster communication (replication, IST, and client connections) is encrypted and authenticated using mutual TLS.

### Client Connections (passbolt-to-Database)

passbolt connects using client certificates configured in `docker-compose.yaml`:

```yaml
DATASOURCES_DEFAULT_SSL_CA: /etc/passbolt/db-ca.crt
DATASOURCES_DEFAULT_SSL_CERT: /etc/passbolt/db-client.crt
DATASOURCES_DEFAULT_SSL_KEY: /etc/passbolt/db-client.key
```

The database requires TLS via `ALTER USER 'passbolt'@'%' REQUIRE SSL;` in the initialization SQL. This enforces mTLS for application connections.

## Deploying to Production

The lab configurations translate directly to physical servers:

**What stays the same:**
- Galera configuration files (`config/mariadb/node*/galera.cnf`) → `/etc/mysql/conf.d/` on servers
- Certificate generation logic → run on your CA host
- MariaDB initialization SQL → apply identically
- Monitoring commands → work on bare metal

**What changes:**
- **Network**: Replace `.local` hostnames with FQDNs (e.g., `galera1.example.com`). Ensure DNS resolution works across all network segments. Use short TTLs (60 seconds) if using DNS round-robin for passbolt frontends.
- **Certificates**: Copy to standard locations (`/etc/mysql/ssl/` for server certs, `/etc/passbolt/db-*.crt` for client certs). Ensure certificate SANs match the FQDNs used in `wsrep_cluster_address`. Plan for certificate renewal before expiration.
- **Firewall**: Open ports 3306 (MariaDB client connections), 4567 (Galera replication), 4444 (SST) between database nodes. Restrict access to trusted networks only.
- **SST encryption**: The lab uses rsync for SST without encryption. For production, you can configure rsync SST to use SSH for encrypted transfers, though be aware that for very large databases (hundreds of GB or more), SST transfers can take hours even over fast networks. Alternatively, consider using `mariabackup` SST method with TLS (`encrypt=3`) if you need encrypted SST transfers.
- **Service management**: Use systemd instead of Docker health checks. Configure proper service dependencies and restart policies.
- **Resource allocation**: Ensure adequate RAM for each MariaDB node (Galera keeps the entire dataset in memory during replication). Plan for network bandwidth between data centers if doing WAN clustering.
- **passbolt configuration sync**: If running multiple passbolt frontends, sync `/etc/passbolt/passbolt.php`, `/etc/passbolt/gpg/`, and `/etc/passbolt/jwt/` across all passbolt servers. See [Louis's HA guide](https://www.passbolt.com/blog/how-to-set-up-a-highly-available-passbolt-environment) for details.

The mTLS configuration is what makes this practical for production. When nodes are in different subnets or data centers, certificates authenticate peers regardless of network location. You can deploy `galera1.example.com` in one rack, `galera2.example.com` in another, and `galera3.example.com` across a WAN link. As long as DNS resolves the hostnames and the certificates are valid, the cluster forms and replicates securely.

## When to Use Galera

For a single passbolt instance with a small team, standalone MariaDB is still simpler. Galera adds operational complexity, so use it when you need:

- **Zero data loss**: Synchronous replication means no replication lag
- **Rolling maintenance**: Upgrade MariaDB versions or apply patches without downtime by upgrading nodes one at a time
- **Disaster recovery**: DR site stays in sync, not behind
- **High availability**: Cluster tolerates single node failures

The complexity is worth it when availability requirements outgrow a single node. The ability to perform rolling upgrades alone can justify the operational overhead when you're managing a service that hundreds of users depend on.

## Quick Reference

**Ports:**
- `3306`: MariaDB client connections - uses mTLS
- `4567`: Galera replication traffic - uses mTLS
- `4444`: State Snapshot Transfer (SST) - out of scope for this lab
- `443`: passbolt HTTPS

**Key configuration files:**
- `config/mariadb/node*/galera.cnf`: Galera cluster configuration
- `docker-compose.yaml`: Container definitions and network aliases
- `scripts/generate-certs.sh`: Certificate generation script
- `certs/`: Generated certificates (CA, server certs, client certs)

**Important Galera settings:**
- `wsrep_cluster_address`: List of all cluster members (e.g., `gcomm://galera1.local,galera2.local,galera3.local`)
- `wsrep_node_address`: This node's advertised address (e.g., `galera1.local:4567`)
- `wsrep_provider_options`: TLS certificate paths for replication mTLS

**Certificate locations (in containers):**
- Server certs: `/etc/mysql/ssl/server-cert.pem`, `/etc/mysql/ssl/server-key.pem`, `/etc/mysql/ssl/ca.pem`
- Client certs: `/etc/passbolt/db-client.crt`, `/etc/passbolt/db-client.key`, `/etc/passbolt/db-ca.crt`

**Key monitoring commands:**
```bash
# Cluster status
SHOW STATUS LIKE 'wsrep_cluster_status';
SHOW STATUS LIKE 'wsrep_cluster_size';
SHOW STATUS LIKE 'wsrep_incoming_addresses';

# TLS verification
SHOW STATUS LIKE 'Ssl_cipher';
SHOW GLOBAL VARIABLES LIKE 'have_ssl';
```

## Troubleshooting

**Cluster won't form:**
- Check DNS resolution: `docker compose exec galera1 getent hosts galera2.local` (or check `/etc/hosts` if using host networking)
- Verify certificates exist: `docker compose exec galera1 ls -la /etc/mysql/ssl/`
- Check cluster address matches DNS names used in `wsrep_cluster_address`
- Review logs: `docker compose logs galera1`

**Certificate validation errors:**
- Ensure certificate SANs include all hostnames used in `wsrep_cluster_address`
- Verify certificate files have correct permissions (readable by mysql user)
- Check certificate expiration: `openssl x509 -in certs/galera1.crt -noout -dates`
- Regenerate certificates if SANs don't match: `/opt/homebrew/bin/bash ./scripts/generate-certs.sh`

**Node in non-primary state:**
- Check if node can resolve other cluster members: `docker compose exec galera2 getent hosts galera1.local`
- Verify `wsrep_cluster_address` lists all members correctly
- Check for network partitions or firewall issues
- Review node logs: `docker compose logs galera2`

**TLS not active:**
- Verify `require_secure_transport=ON` in galera.cnf
- Check certificate paths in `wsrep_provider_options` are correct
- Ensure MariaDB has SSL support: `SHOW GLOBAL VARIABLES LIKE 'have_ssl';` should return `YES`
- Verify client certificates are mounted correctly in docker-compose.yaml

**passbolt can't connect to database:**
- Check passbolt can resolve database hostname: `docker compose exec passbolt getent hosts galera1.local`
- Verify client certificates are mounted: `docker compose exec passbolt ls -la /etc/passbolt/db-*.crt`
- Check database user requires SSL: `SHOW GRANTS FOR 'passbolt'@'%';` should show `REQUIRE SSL`
- Review passbolt logs: `docker compose logs passbolt`

## Further Reading

**Essential resources:**
- [Galera Cluster best practices](https://galeracluster.com/2025/01/your-mysql-mariadb-galera-cluster-and-galera-manager-best-practice-resources/)
- [Known limitations](https://mariadb.com/docs/galera-cluster/reference/mariadb-galera-cluster-known-limitations)
- [Backing up a MariaDB Galera cluster](https://mariadb.com/docs/galera-cluster/galera-management/general-operations/backing-up-a-mariadb-galera-cluster)
- [Rolling upgrades](https://mariadb.com/docs/galera-cluster/galera-management/upgrading-galera-cluster/) for zero-downtime MariaDB version upgrades

**Production tools:**
- [ProxySQL with native Galera support](https://proxysql.com/blog/proxysql-native-galera-support/) for connection pooling and load balancing (open source, database-aware proxy)
- [HAProxy](https://mariadb.com/docs/galera-cluster/high-availability/load-balancing/load-balancing-in-mariadb-galera-cluster#other-load-balancing-solutions) for TCP load balancing (open source, typically uses TCP health checks or custom scripts)
- [MaxScale](https://mariadb.com/docs/galera-cluster/high-availability/load-balancing/load-balancing-in-mariadb-galera-cluster) for database proxy and query routing (commercial, recommended by MariaDB for Galera)
- Cloud load balancers: AWS (ELB/NLB), Google Cloud, and Azure offer native load balancing services for Galera clusters
- [Galera Manager](https://galeracluster.com/galera-mgr/) for cluster monitoring and management (commercial)

**Community forum**
> I hope you find time to give MariaDB Galera Cluster a try and please let me know your thoughts on the passbolt community forum thread: ["passbolt with MariaDB Galera Cluster using Mutual TLS (mTLS) authentication"](https://community.passbolt.com/)

