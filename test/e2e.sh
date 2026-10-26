#!/bin/sh
# End-to-end check of the image, run by hand before a release:
#   1. a backup of a throwaway Postgres lands in a throwaway MinIO bucket,
#      and the dump in the bucket lists the seeded table;
#   2. a wrong password fails the step without printing the password;
#   3. a missing setting and an unsafe cli_version are refused.
# Needs Docker and network access to the npm registry. Removes the containers
# and the network it creates; the image under test is left alone.
#
#   docker build -t woodpecker-backupdrill:test .
#   IMAGE=woodpecker-backupdrill:test test/e2e.sh
set -eu

image=${IMAGE:-woodpecker-backupdrill:test}
postgres_image=${POSTGRES_IMAGE:-postgres:17-alpine}
# MinIO no longer publishes images on Docker Hub; Chainguard builds it from source.
minio_image=${MINIO_IMAGE:-cgr.dev/chainguard/minio:latest}
mc_image=${MC_IMAGE:-cgr.dev/chainguard/minio-client:latest}

run_id=wpbd-e2e-$$
network=$run_id
postgres=$run_id-postgres
minio=$run_id-minio
log_dir=$(mktemp -d)

random() { od -An -N12 -tx1 /dev/urandom | tr -d ' \n'; }
postgres_password=$(random)
minio_user=e2e$(random)
minio_password=$(random)

cleanup() {
  docker rm -f "$postgres" "$minio" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$log_dir"
}
trap cleanup EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mc() {
  docker run --rm --network "$network" \
    -e "MC_HOST_e2e=http://$minio_user:$minio_password@$minio:9000" "$mc_image" "$@"
}

retry() {
  tries=0
  until "$@" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 30 ] || fail "timed out waiting for: $*"
    sleep 1
  done
}

docker network create "$network" >/dev/null
docker run -d --name "$postgres" --network "$network" \
  -e POSTGRES_PASSWORD="$postgres_password" "$postgres_image" >/dev/null
docker run -d --name "$minio" --network "$network" \
  -e MINIO_ROOT_USER="$minio_user" -e MINIO_ROOT_PASSWORD="$minio_password" \
  "$minio_image" server /data >/dev/null

retry docker exec "$postgres" pg_isready -U postgres -h 127.0.0.1
docker exec "$postgres" psql -q -U postgres -v ON_ERROR_STOP=1 -c "
  create table public.todos (id serial primary key, title text not null);
  insert into public.todos (title) select 'task ' || n from generate_series(1, 250) as n;
  analyze public.todos;"
retry mc mb e2e/backups

# Runs the plugin image the way the Woodpecker docker backend does: settings
# arrive as PLUGIN_* variables. Values are passed by name so they stay out of argv.
run_plugin() {
  docker run --rm --network "$network" \
    -e PLUGIN_DATABASE_URL -e PLUGIN_PROJECT_NAME -e PLUGIN_S3_ENDPOINT -e PLUGIN_S3_REGION \
    -e PLUGIN_S3_BUCKET -e PLUGIN_S3_ACCESS_KEY_ID -e PLUGIN_S3_SECRET_ACCESS_KEY \
    -e PLUGIN_CLI_VERSION "$image"
}

export PLUGIN_DATABASE_URL="postgresql://postgres:$postgres_password@$postgres:5432/postgres"
export PLUGIN_PROJECT_NAME=e2e
export PLUGIN_S3_ENDPOINT="http://$minio:9000"
export PLUGIN_S3_REGION=us-east-1
export PLUGIN_S3_BUCKET=backups
export PLUGIN_S3_ACCESS_KEY_ID="$minio_user"
export PLUGIN_S3_SECRET_ACCESS_KEY="$minio_password"
export PLUGIN_CLI_VERSION=

echo "== 1. backup"
status=0
run_plugin >"$log_dir/backup.log" 2>&1 || status=$?
cat "$log_dir/backup.log"
[ "$status" -eq 0 ] || fail "backup exited with $status"
mc ls --recursive e2e/backups | tee "$log_dir/bucket.txt"
for file in dump.pgcustom manifest.json RECOVERY.md; do
  grep -q "e2e/.*/$file" "$log_dir/bucket.txt" || fail "$file missing from the bucket"
done
dump_key=$(sed -n 's/.* \(backupdrill\/e2e\/.*\/dump\.pgcustom\)$/\1/p' "$log_dir/bucket.txt")
mc cat "e2e/backups/$dump_key" |
  docker run -i --rm --entrypoint pg_restore "$image" --list |
  grep -q "TABLE DATA public todos" || fail "the dump has no data for public.todos"
echo "ok: snapshot is in the bucket and its dump holds public.todos"

echo "== 2. wrong password"
wrong_password=wrong$(random)
status=0
(
  export PLUGIN_DATABASE_URL="postgresql://postgres:$wrong_password@$postgres:5432/postgres"
  run_plugin
) >"$log_dir/wrong.log" 2>&1 || status=$?
cat "$log_dir/wrong.log"
[ "$status" -ne 0 ] || fail "a wrong password should fail the step"
echo "exit code: $status"
for secret in "$wrong_password" "$postgres_password" "$minio_password"; do
  if grep -qF "$secret" "$log_dir/wrong.log"; then fail "a secret was printed"; fi
done
echo "ok: failed without printing a secret"

echo "== 3. refused settings"
# Subshells, so the changed setting doesn't outlive the check.
(export PLUGIN_DATABASE_URL=; run_plugin) >"$log_dir/missing.log" 2>&1 &&
  fail "a missing database_url should fail"
grep -q "database_url setting is required" "$log_dir/missing.log" ||
  fail "unclear message: $(cat "$log_dir/missing.log")"
(export PLUGIN_CLI_VERSION=latest; run_plugin) >"$log_dir/version.log" 2>&1 &&
  fail "cli_version=latest should be refused"
grep -q "cli_version must be a version number" "$log_dir/version.log" ||
  fail "unclear message: $(cat "$log_dir/version.log")"
echo "ok: missing setting and unsafe cli_version refused"

echo "PASS"
