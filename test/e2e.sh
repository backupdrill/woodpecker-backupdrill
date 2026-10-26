#!/bin/sh
# End-to-end check of the image, run by hand before a release:
#   1. for PostgreSQL 15 to 18: the plugin backs up a seeded table into a MinIO
#      bucket with the matching pg_dump, and the dump restores onto a server of
#      the same version (pg_restore runs from the image, as a user would);
#   2. a wrong password fails the step without printing the password, and the
#      ping_url gets its start and fail pings;
#   3. when the server version is unknown, the CLI dumps nothing even though
#      the database is reachable (the plugin never guesses a pg_dump);
#   4. a missing setting is refused with its name.
# Everything runs on a Docker network with no route out, so a run that tried to
# download something would fail. Needs Docker. Removes the containers and the
# network it creates; the image under test is left alone.
#
#   docker build -t woodpecker-backupdrill:test .
#   IMAGE=woodpecker-backupdrill:test test/e2e.sh
set -eu

image=${IMAGE:-woodpecker-backupdrill:test}
postgres_versions=${POSTGRES_VERSIONS:-15 16 17 18}
# MinIO no longer publishes images on Docker Hub; Chainguard builds it from source.
minio_image=${MINIO_IMAGE:-cgr.dev/chainguard/minio:latest}
mc_image=${MC_IMAGE:-cgr.dev/chainguard/minio-client:latest}

run_id=wpbd-e2e-$$
network=$run_id
postgres=$run_id-postgres
minio=$run_id-minio
pings=$run_id-pings
log_dir=$(mktemp -d)

random() { od -An -N12 -tx1 /dev/urandom | tr -d ' \n'; }
postgres_password=$(random)
minio_user=e2e$(random)
minio_password=$(random)

cleanup() {
  docker rm -f "$postgres" "$minio" "$pings" >/dev/null 2>&1 || true
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

psql_in() {
  docker exec "$postgres" psql -q -At -U postgres -v ON_ERROR_STOP=1 "$@"
}

start_postgres() {
  docker rm -f "$postgres" >/dev/null 2>&1 || true
  docker run -d --name "$postgres" --network "$network" \
    -e POSTGRES_PASSWORD="$postgres_password" "postgres:$1-alpine" >/dev/null
  retry psql_in -h 127.0.0.1 -c "select 1"
  psql_in -c "
    create table public.todos (id serial primary key, title text not null);
    insert into public.todos (title) select 'task ' || n from generate_series(1, 250) as n;
    analyze public.todos;"
}

# Runs the plugin image the way the Woodpecker docker backend does: settings
# arrive as PLUGIN_* variables. Values are passed by name so they stay out of argv.
run_plugin() {
  docker run --rm --network "$network" \
    -e PLUGIN_DATABASE_URL -e PLUGIN_PROJECT_NAME -e PLUGIN_S3_ENDPOINT -e PLUGIN_S3_REGION \
    -e PLUGIN_S3_BUCKET -e PLUGIN_S3_ACCESS_KEY_ID -e PLUGIN_S3_SECRET_ACCESS_KEY "$image"
}

# --internal: no route out of this network.
docker network create --internal "$network" >/dev/null
docker run -d --name "$minio" --network "$network" \
  -e MINIO_ROOT_USER="$minio_user" -e MINIO_ROOT_PASSWORD="$minio_password" \
  "$minio_image" server /data >/dev/null
retry mc mb e2e/backups

export PLUGIN_DATABASE_URL="postgresql://postgres:$postgres_password@$postgres:5432/postgres"
export PLUGIN_S3_ENDPOINT="http://$minio:9000"
export PLUGIN_S3_REGION=us-east-1
export PLUGIN_S3_BUCKET=backups
export PLUGIN_S3_ACCESS_KEY_ID="$minio_user"
export PLUGIN_S3_SECRET_ACCESS_KEY="$minio_password"

for version in $postgres_versions; do
  echo "== 1. backup and restore, PostgreSQL $version"
  start_postgres "$version"
  # The image has pg_dump 16 to 18; older servers get 16.
  expected_major=$((version < 16 ? 16 : version))
  export PLUGIN_PROJECT_NAME="pg$version"

  status=0
  run_plugin >"$log_dir/backup.log" 2>&1 || status=$?
  cat "$log_dir/backup.log"
  [ "$status" -eq 0 ] || fail "backup exited with $status"
  grep -q "pg_dump (PostgreSQL) $expected_major\." "$log_dir/backup.log" ||
    fail "expected pg_dump $expected_major for PostgreSQL $version"

  mc ls --recursive "e2e/backups/backupdrill/pg$version/" >"$log_dir/bucket.txt"
  cat "$log_dir/bucket.txt"
  for file in dump.pgcustom manifest.json RECOVERY.md; do
    grep -q "/$file\$" "$log_dir/bucket.txt" || fail "$file missing from the bucket"
  done
  dump_key=$(sed -n 's/.* \([^ ]*\/dump\.pgcustom\)$/\1/p' "$log_dir/bucket.txt")

  # Restore into a new database on the same server with the image's pg_restore
  # of the dump's major, in one transaction that stops at the first error, like
  # `backupdrill restore`. The dump creates schema public itself, so the target
  # starts without it.
  psql_in -c "create database restored"
  psql_in -d restored -c "drop schema public"
  mc cat "e2e/backups/backupdrill/pg$version/$dump_key" |
    docker run -i --rm --network "$network" -e PGPASSWORD="$postgres_password" \
      --entrypoint "/usr/libexec/postgresql$expected_major/pg_restore" "$image" \
      --no-owner --no-privileges --single-transaction --exit-on-error \
      -h "$postgres" -U postgres -d restored ||
    fail "the PostgreSQL $version dump did not restore onto PostgreSQL $version"
  rows=$(psql_in -d restored -c "select count(*) from public.todos")
  [ "$rows" = 250 ] || fail "restored $rows rows instead of 250"
  echo "ok: PostgreSQL $version backed up with pg_dump $expected_major and restored with all 250 rows"
done

echo "== 2. wrong password, with ping_url"
# A stand-in for Healthchecks that logs each request it gets.
docker run -d --name "$pings" --network "$network" --entrypoint node "$image" -e "
  require('http').createServer((req, res) => { console.log(req.method, req.url); res.end('OK'); }).listen(8000);
" >/dev/null
retry docker exec "$pings" node -e "fetch('http://127.0.0.1:8000/ready').then(() => {}, () => process.exit(1))"
wrong_password=wrong$(random)
status=0
(
  export PLUGIN_DATABASE_URL="postgresql://postgres:$wrong_password@$postgres:5432/postgres"
  export PLUGIN_PING_URL="http://$pings:8000/ping"
  docker run --rm --network "$network" -e PLUGIN_DATABASE_URL -e PLUGIN_PING_URL \
    -e PLUGIN_S3_ENDPOINT -e PLUGIN_S3_REGION -e PLUGIN_S3_BUCKET \
    -e PLUGIN_S3_ACCESS_KEY_ID -e PLUGIN_S3_SECRET_ACCESS_KEY "$image"
) >"$log_dir/wrong.log" 2>&1 || status=$?
cat "$log_dir/wrong.log"
[ "$status" -ne 0 ] || fail "a wrong password should fail the step"
echo "exit code: $status"
for secret in "$wrong_password" "$postgres_password" "$minio_password"; do
  if grep -qF "$secret" "$log_dir/wrong.log"; then fail "a secret was printed"; fi
done
docker logs "$pings" >"$log_dir/pings.log" 2>&1
grep -q "^POST /ping/start" "$log_dir/pings.log" || fail "no start ping"
grep -q "^POST /ping/fail" "$log_dir/pings.log" || fail "no fail ping"
echo "ok: failed without printing a secret, and pinged start and fail"

echo "== 3. unknown server version"
# The entrypoint hands the CLI no-pg-dump when it can't read the version. Run
# the CLI that way against a database it can reach: it has to stop before
# writing anything to the bucket.
status=0
docker run --rm --network "$network" --entrypoint /opt/backupdrill/node_modules/.bin/backupdrill \
  -e BACKUPDRILL_DATABASE_URL="$PLUGIN_DATABASE_URL" -e BACKUPDRILL_PROJECT_NAME=unknown-version \
  -e BACKUPDRILL_S3_ENDPOINT="$PLUGIN_S3_ENDPOINT" -e BACKUPDRILL_S3_REGION="$PLUGIN_S3_REGION" \
  -e BACKUPDRILL_S3_BUCKET="$PLUGIN_S3_BUCKET" -e BACKUPDRILL_S3_ACCESS_KEY_ID="$minio_user" \
  -e BACKUPDRILL_S3_SECRET_ACCESS_KEY="$minio_password" \
  -e BACKUPDRILL_PG_DUMP=/opt/backupdrill/no-pg-dump "$image" backup >"$log_dir/unknown.log" 2>&1 || status=$?
cat "$log_dir/unknown.log"
[ "$status" -ne 0 ] || fail "the backup should fail without a picked pg_dump"
grep -q "picked no pg_dump" "$log_dir/unknown.log" || fail "unclear message"
if [ -n "$(mc ls --recursive e2e/backups/backupdrill/unknown-version/ 2>/dev/null)" ]; then
  fail "something was written to the bucket"
fi
echo "ok: nothing dumped without a picked pg_dump"

echo "== 4. missing setting"
# A subshell, so the emptied setting doesn't outlive the check.
(export PLUGIN_DATABASE_URL=; run_plugin) >"$log_dir/missing.log" 2>&1 &&
  fail "a missing database_url should fail"
grep -q "database_url setting is required" "$log_dir/missing.log" ||
  fail "unclear message: $(cat "$log_dir/missing.log")"
echo "ok: missing database_url refused"

echo "PASS"
