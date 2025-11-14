-- Enforce mutual TLS (mTLS) for the Passbolt database user.
-- This requires Passbolt to present a client certificate when connecting.
-- Combined with require_secure_transport=ON in galera.cnf, this enforces mTLS:
--   1. Server presents its certificate (standard TLS)
--   2. Client (Passbolt) must present its certificate (mTLS requirement)
--   3. Both sides verify each other's certificates using the shared CA
--
-- Reference: https://mariadb.com/docs/server/reference/sql-statements/account-management-sql-statements/alter-user#tls-options
ALTER USER 'passbolt'@'%' REQUIRE SSL;

