# Supabase backup plugin for Woodpecker CI

A [Woodpecker CI](https://woodpecker-ci.org) plugin that dumps a Supabase or Postgres database with `pg_dump` and uploads it to your own S3, R2, B2 or MinIO bucket, together with a checksummed `manifest.json` and a `RECOVERY.md`. The usual place for it is right before the step that runs your migrations.

```yaml
steps:
  - name: backup-database
    image: ghcr.io/backupdrill/woodpecker-backupdrill:1
    settings:
      database_url:
        from_secret: database_url
      s3_endpoint: https://<account-id>.r2.cloudflarestorage.com
      s3_bucket: my-db-backups
      s3_access_key_id:
        from_secret: backup_access_key_id
      s3_secret_access_key:
        from_secret: backup_secret_access_key
```

All settings, the PostgreSQL version notes and what to know about secrets are in [docs.md](docs.md). Woodpecker's plugin index shows the same file.

## How it works

The image is `node:24-alpine3.24` with the PostgreSQL 16, 17 and 18 clients, [the backupdrill CLI](https://backupdrill.com/docs/cli) and [entrypoint.sh](entrypoint.sh). The CLI version and every dependency are pinned in [package-lock.json](package-lock.json) and installed with `npm ci` at build time, so a run downloads nothing.

The entrypoint turns the step's settings into the CLI's environment variables, asks the server for its major version ([server-major.mjs](server-major.mjs), using the CLI's own connection settings) and points the CLI at the pg_dump of that version, so the dump can be restored onto the same version. Then it runs `backupdrill backup`, which streams the dump to the bucket and writes the manifest last.

The CLI doesn't depend on any BackupDrill server, so an image keeps working when newer CLI versions come out. Rebuild when you want a newer CLI, when a server moves past PostgreSQL 18, or before Node.js 24 reaches end of life in April 2028.

## Testing

Both tests use throwaway Postgres and MinIO containers and clean up after themselves.

```sh
docker build -t woodpecker-backupdrill:test .

# docker run, the way the Woodpecker Docker backend starts a plugin
IMAGE=woodpecker-backupdrill:test test/e2e.sh

# a real pipeline through woodpecker-cli
woodpecker-cli exec --secrets-file secrets.yaml test/pipeline.yaml
```

`test/e2e.sh` runs on a Docker network with no internet access. For PostgreSQL 15, 16, 17 and 18 it backs up a seeded table, checks which pg_dump ran, and restores the dump from the bucket onto a server of the same version. Then it checks that a wrong password fails the step without showing up in the log, and that a missing setting is refused.

For `woodpecker-cli exec`, `secrets.yaml` needs `postgres_password`, `minio_user`, `minio_password`, `mc_host` (`http://<minio_user>:<minio_password>@minio:9000`) and `database_url` (`postgresql://postgres:<postgres_password>@postgres:5432/postgres`). Keep that file out of the repository.

## Releasing

To move to another CLI version, update the lockfile with the same npm the image uses, then build and run the tests:

```sh
docker run --rm -v "$PWD:/w" -w /w node:24-alpine3.24 \
  npm install --package-lock-only --ignore-scripts --save-exact backupdrill@<version>
```

Push a tag such as `v1.0.1`. The release workflow builds the image for linux/amd64 and linux/arm64 and pushes it to `ghcr.io/backupdrill/woodpecker-backupdrill` as `1.0.1`, `1` and `latest`.

## License

MIT
