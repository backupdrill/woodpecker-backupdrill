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

The image is `node:24-alpine3.24` with the PostgreSQL 18 client and [entrypoint.sh](entrypoint.sh). On each run the entrypoint turns the step's settings into the environment variables of [the backupdrill CLI](https://backupdrill.com/docs/cli), installs `backupdrill@2` from npm (or the version in `cli_version`) and runs `backupdrill backup`. The CLI does the actual work: it checks pg_dump against the server version, streams the dump to the bucket and writes the manifest last.

Because the CLI is fetched at run time, CLI fixes don't need a new image. The image only has to be rebuilt for a newer pg_dump or Node.js.

## Testing

Both tests use a throwaway Postgres 17 and MinIO in Docker and clean up after themselves.

```sh
docker build -t woodpecker-backupdrill:test .

# docker run, the way the Woodpecker Docker backend starts a plugin
IMAGE=woodpecker-backupdrill:test test/e2e.sh

# a real pipeline through woodpecker-cli
woodpecker-cli exec --secrets-file secrets.yaml test/pipeline.yaml
```

`test/e2e.sh` backs up a seeded table and checks the dump in the bucket, then checks that a wrong password fails the step without showing up in the log, and that a missing setting or a `cli_version` like `latest` is refused.

For `woodpecker-cli exec`, `secrets.yaml` needs `postgres_password`, `minio_user`, `minio_password`, `mc_host` (`http://<minio_user>:<minio_password>@minio:9000`) and `database_url` (`postgresql://postgres:<postgres_password>@postgres:5432/postgres`). Keep that file out of the repository.

## Releasing

Push a tag such as `v1.0.1`. The release workflow builds the image for linux/amd64 and linux/arm64 and pushes it to `ghcr.io/backupdrill/woodpecker-backupdrill` as `1.0.1`, `1` and `latest`.

## License

MIT
