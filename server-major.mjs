// Prints the database server's major version so the entrypoint can pick the
// pg_dump of that major. It connects with the CLI's own connection settings
// (pgConnectOptions verifies Supabase's certificate). On failure it prints the
// error message and exits non-zero, and the entrypoint stops the step.
import pg from "pg";
import { assertNoHostOverride, pgConnectOptions } from "backupdrill";

async function serverMajor(url) {
  assertNoHostOverride(url);
  const client = new pg.Client({ ...pgConnectOptions(url), connectionTimeoutMillis: 30000 });
  // Without a listener, a dropped connection would surface as an uncaught exception.
  client.on("error", () => {});
  await client.connect();
  try {
    const { rows } = await client.query("show server_version_num");
    return Math.floor(Number(rows[0].server_version_num) / 10000);
  } finally {
    await client.end();
  }
}

try {
  console.log(await serverMajor(process.env.BACKUPDRILL_DATABASE_URL));
} catch (error) {
  // Only the message: Postgres and network errors name the user and the host,
  // never the password.
  console.error(`woodpecker-backupdrill: could not read the server version: ${error.message}`);
  process.exitCode = 1;
}
