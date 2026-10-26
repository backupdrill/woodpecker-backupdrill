// Prints the database server's major version so the entrypoint can pick the
// pg_dump of that major. It connects with the CLI's own connection settings
// (pgConnectOptions verifies Supabase's certificate), and on any failure it
// prints nothing: the CLI then connects by itself and reports the error.
import pg from "pg";
import { assertNoHostOverride, pgConnectOptions } from "backupdrill";

const url = process.env.BACKUPDRILL_DATABASE_URL;
assertNoHostOverride(url);

const client = new pg.Client({ ...pgConnectOptions(url), connectionTimeoutMillis: 30000 });
// Without a listener, a dropped connection would surface as an uncaught exception.
client.on("error", () => {});
await client.connect();
try {
  const { rows } = await client.query("show server_version_num");
  console.log(Math.floor(Number(rows[0].server_version_num) / 10000));
} finally {
  await client.end();
}
