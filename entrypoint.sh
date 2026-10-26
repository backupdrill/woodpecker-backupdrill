#!/bin/sh
# Woodpecker hands the step's settings to the plugin as PLUGIN_* variables.
# This script maps them onto the BACKUPDRILL_* variables the CLI reads and runs
# `backupdrill backup`. The CLI and its dependencies were installed from
# package-lock.json when the image was built, so nothing is downloaded here.
# The script never prints a setting's value.
set -eu

cli=/opt/backupdrill/node_modules/.bin/backupdrill

die() {
  echo "woodpecker-backupdrill: $*" >&2
  exit 1
}

setting() {
  printenv "PLUGIN_$1" || true
}

# Checked here rather than left to the CLI, so the error names the setting the
# user wrote in the pipeline instead of the CLI's environment variable.
for name in DATABASE_URL S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
  if [ -z "$(setting "$name")" ]; then
    die "the $(echo "$name" | tr '[:upper:]' '[:lower:]') setting is required"
  fi
done

# Settings are the only configuration. Values the agent or the pipeline set for
# other steps (DATABASE_URL is a common one, and the CLI falls back to it) must
# not leak into the backup, and pg_dump has to be the one shipped in this image.
unset DATABASE_URL BACKUPDRILL_PG_DUMP
for name in DATABASE_URL PROJECT_NAME SCHEMAS \
  S3_ENDPOINT S3_REGION S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_PREFIX S3_FORCE_PATH_STYLE \
  SUPABASE_STORAGE_ENDPOINT SUPABASE_STORAGE_REGION SUPABASE_STORAGE_ACCESS_KEY_ID \
  SUPABASE_STORAGE_SECRET_ACCESS_KEY SUPABASE_STORAGE_BUCKETS PING_URL; do
  value=$(setting "$name")
  if [ -n "$value" ]; then
    export "BACKUPDRILL_$name=$value"
  else
    unset "BACKUPDRILL_$name"
  fi
done

# Use the pg_dump of the server's major version, or the oldest one here for
# servers older than that. An archive needs a pg_restore at least as new as the
# pg_dump that wrote it, and pg_restore 17 and newer can't restore into
# PostgreSQL 16 or older, so a newer pg_dump would make the backup impossible to
# load back onto the version it came from. When the version can't be read, the
# step stops here instead of guessing. For a server newer than every pg_dump
# here, the CLI gets the newest one and refuses with a version error.
server_major=$(node /opt/backupdrill/server-major.mjs) || exit 1
case $server_major in
  '' | *[!0-9]*) die "unexpected server version: $server_major" ;;
esac
for dir in /usr/libexec/postgresql[0-9]*; do
  if [ "${dir#/usr/libexec/postgresql}" -ge "$server_major" ]; then
    export BACKUPDRILL_PG_DUMP="$dir/pg_dump"
    break
  fi
done

# Run outside the repository checkout, so the CLI doesn't read a
# backupdrill.config.json from it.
cd "$(mktemp -d)"

echo "▶  backupdrill $("$cli" --version) backup, $("${BACKUPDRILL_PG_DUMP:-pg_dump}" --version)"
# Progress goes to stderr. stdout carries the whole manifest as one JSON line,
# which for a project with Storage files lists every file; the same manifest is
# already in the bucket next to the dump.
exec "$cli" backup >/dev/null
