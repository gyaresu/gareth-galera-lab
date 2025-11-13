-- Ensure the Passbolt account connects over TLS.
-- Reference: https://mariadb.com/docs/server/reference/sql-statements/account-management-sql-statements/alter-user#tls-options
ALTER USER 'passbolt'@'%' REQUIRE SSL;

