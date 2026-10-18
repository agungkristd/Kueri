# Third-party notices

Kueri's own code is under the [MIT License](LICENSE). Building from source links against the
libraries below; the release DMG also ships them inside the app (`Contents/Frameworks`,
`Contents/Helpers`), with their full license texts in `Kueri.app/Contents/Resources/Licenses`,
copied from the installed packages by `package.sh`.

| Component | Used for | License |
|---|---|---|
| [libpq](https://www.postgresql.org) and `pg_dump`, `pg_restore`, `psql` (PostgreSQL client) | PostgreSQL connections, export and import | [PostgreSQL License](https://www.postgresql.org/about/licence/) |
| [OpenSSL 3](https://www.openssl.org) (`libssl`, `libcrypto`) | TLS for MySQL, Redis and PostgreSQL | [Apache License 2.0](https://www.openssl.org/source/apache-license-2.0.txt) |
| [MIT Kerberos](https://web.mit.edu/kerberos/) (`libgssapi_krb5` and its libraries) | Loaded by libpq for GSSAPI authentication | MIT and related permissive licenses ([NOTICE](https://github.com/krb5/krb5/blob/master/NOTICE)) |

SQLite, the `sqlite3` tool and `ssh` are part of macOS and aren't shipped with Kueri.

This product includes software developed by the OpenSSL Project for use in the OpenSSL Toolkit
(https://www.openssl.org/).
