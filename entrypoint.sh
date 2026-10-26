#!/bin/sh
# Woodpecker hands the step's settings to the plugin as PLUGIN_* variables.
# This script maps them onto the BACKUPDRILL_* variables the CLI reads, installs
# the CLI from npm and runs `backupdrill backup`. It never prints a setting's value.
set -eu

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

# The CLI is fetched on every run, so fixes in 2.x arrive without rebuilding this
# image. Only digits and dots are accepted: a tag, URL or git spec would let the
# pipeline swap in different code that then runs with the database password.
cli_version=$(setting CLI_VERSION)
cli_version=${cli_version:-2}
case $cli_version in
  *[!0-9.]* | .* | *. | *..*)
    die "cli_version must be a version number such as 2, 2.7 or 2.7.1, got: $cli_version" ;;
esac

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

# Work outside the repository checkout: npm would otherwise pick up an .npmrc or
# node_modules from it, and the CLI would read a backupdrill.config.json there.
workdir=$(mktemp -d)
cd "$workdir"
export npm_config_cache="$workdir/.npm" npm_config_update_notifier=false

echo "▶  Install backupdrill@$cli_version"
npm install --prefix "$workdir" --no-audit --no-fund --ignore-scripts "backupdrill@$cli_version"
cli="$workdir/node_modules/.bin/backupdrill"

echo "▶  backupdrill $("$cli" --version) backup"
# Progress goes to stderr. stdout carries the whole manifest as one JSON line,
# which for a project with Storage files lists every file; the same manifest is
# already in the bucket next to the dump.
exec "$cli" backup >/dev/null
