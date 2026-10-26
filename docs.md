---
name: Supabase Backup
icon: https://raw.githubusercontent.com/backupdrill/woodpecker-backupdrill/main/icon.svg
description: Dump a Supabase or Postgres database to your own S3, R2 or B2 bucket, for example right before a deploy runs migrations
author: Super Lede
tags: [backup, postgres, supabase, database, pg_dump, s3]
containerImage: ghcr.io/backupdrill/woodpecker-backupdrill
containerImageUrl: https://github.com/backupdrill/woodpecker-backupdrill/pkgs/container/woodpecker-backupdrill
url: https://github.com/backupdrill/woodpecker-backupdrill
---

Dumps a Postgres database with `pg_dump` and uploads it to a bucket you own: AWS S3, Cloudflare R2, Backblaze B2, MinIO or anything else that speaks the S3 API. Next to the dump it writes a `manifest.json` (tables, estimated row counts, sizes, SHA-256 checksums) and a `RECOVERY.md` with restore steps. For Supabase projects it can copy Storage files too.

The step runs [the backupdrill CLI](https://backupdrill.com/docs/cli), an open-source Supabase backup tool. The dump goes from your database through the Woodpecker agent straight to your bucket.

## Back up before a deploy

Put the step in front of the one that runs your migrations. Steps run in order, so if the backup fails, the deploy doesn't start.

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
    when:
      - event: push
        branch: main

  - name: migrate
    image: your-deploy-image
    commands:
      - ./migrate.sh
    when:
      - event: push
        branch: main
```

For Supabase, use the Session pooler connection string: open the project in the dashboard, click **Connect** and pick **Session pooler**. The default `postgres` user works.

For AWS S3, leave out `s3_endpoint` and set `s3_region` (for example `us-east-1`).

To back up on a schedule instead, create a cron job in the repository settings and run the step with `when: event: cron`. Each backup reads the whole database, which counts as egress on a Supabase bill, so read the [egress notes in the CLI docs](https://backupdrill.com/docs/cli#egress-cost-read-before-scheduling-daily-backups) before you schedule it daily.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| `database_url` | required | Postgres connection string. Pass it with `from_secret`. |
| `s3_bucket` | required | Bucket the backup is written to. |
| `s3_access_key_id` | required | Access key for that bucket. Pass it with `from_secret`. |
| `s3_secret_access_key` | required | Secret key for that bucket. Pass it with `from_secret`. |
| `s3_endpoint` | none | Endpoint of an S3-compatible service (R2, B2, MinIO). Leave it out for AWS S3. |
| `s3_region` | `auto` | Bucket region. AWS S3 needs a real region. |
| `s3_prefix` | `backupdrill` | Key prefix inside the bucket. |
| `s3_force_path_style` | `true` when `s3_endpoint` is set | Path-style addressing (`true` or `false`). |
| `project_name` | `supabase` | Name used in the object keys and the manifest. |
| `schemas` | `public` | Schemas to dump, as a list or comma-separated. |
| `supabase_storage_endpoint`, `supabase_storage_region`, `supabase_storage_access_key_id`, `supabase_storage_secret_access_key` | none | Set all four to copy Supabase Storage files as well. Create the keys under **Storage > Settings > S3 Access Keys** and pass them with `from_secret`. |
| `supabase_storage_buckets` | all buckets | Storage buckets to copy, as a list or comma-separated. |
| `ping_url` | none | A [Healthchecks.io](https://healthchecks.io) ping URL. The CLI pings it when the backup starts, succeeds or fails. |
| `cli_version` | `2` | backupdrill version to run, such as `2.7.1`. Only version numbers are accepted. |

The settings map one to one onto the CLI's `BACKUPDRILL_*` environment variables. The plugin ignores those variables (and `DATABASE_URL`) if they are set any other way, so only the step's settings decide what gets backed up.

A backup ends up here:

```text
<s3_prefix>/<project_name>/<timestamp>/
  dump.pgcustom            pg_dump custom format
  storage/<bucket>/<key>   only with the Storage settings
  RECOVERY.md
  manifest.json            written last, so a snapshot without it is incomplete
```

## PostgreSQL versions

The image ships pg_dump 18, which can dump servers from PostgreSQL 9.2 to 18. That covers every Supabase project today (15 to 17). The CLI compares versions before it dumps and stops with an error if the server is newer than pg_dump.

A dump made by pg_dump 18 needs pg_restore 18 or newer. `RECOVERY.md` in each snapshot names the version, and `backupdrill restore` checks it before it writes anything.

If your server is newer than 18, run the CLI in a regular step with a newer client and set `BACKUPDRILL_PG_DUMP` to its path:

```yaml
steps:
  - name: backup-database
    image: node:24-alpine
    environment:
      BACKUPDRILL_DATABASE_URL:
        from_secret: database_url
      BACKUPDRILL_S3_ENDPOINT: https://<account-id>.r2.cloudflarestorage.com
      BACKUPDRILL_S3_BUCKET: my-db-backups
      BACKUPDRILL_S3_ACCESS_KEY_ID:
        from_secret: backup_access_key_id
      BACKUPDRILL_S3_SECRET_ACCESS_KEY:
        from_secret: backup_secret_access_key
      BACKUPDRILL_PG_DUMP: /usr/libexec/postgresql19/pg_dump
    commands:
      - apk add --no-cache postgresql19-client
      - npx --yes backupdrill@2 backup
```

## How the CLI gets into the image

The image holds Node.js 24, pg_dump and a small entrypoint script. The CLI itself is installed from the npm registry at the start of every run, as `backupdrill@2` unless you set `cli_version`. Bug fixes in 2.x reach you without a new image, and a future 3.0 won't change what the plugin runs. The agent needs to reach `registry.npmjs.org`, your database and your bucket.

Set `cli_version` to an exact version such as `2.7.1` if you want every run to use the same code.

## Secrets

The plugin never prints settings, and the CLI hands the database password to pg_dump through the environment rather than the command line. Woodpecker also masks secret values in the log.

Anyone who can edit the pipeline file can change the other settings as well, for example point `s3_endpoint` at a server they control and receive the dump. Restricting the secrets to this image with the plugins filter doesn't prevent that. Only make the secrets available to branches and events you trust, and keep them away from pull requests (Woodpecker withholds secrets from pull request events by default).

## Restoring

The plugin only takes backups. To restore one, or to check that it restores at all, use the CLI from your own machine: `backupdrill drill` restores the latest snapshot into a throwaway Postgres in Docker and checks it against the manifest, and `backupdrill restore` puts a snapshot into a new Supabase project. Each snapshot's `RECOVERY.md` also has the plain `pg_restore` commands.
