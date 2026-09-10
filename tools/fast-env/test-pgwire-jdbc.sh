#!/usr/bin/env bash
# JDBC proof for the fast-env PG-wire stub (healthy scenario).
#
# Starts one pgwire-stub.py process per node tuple, then runs the real
# PostgreSQL JDBC driver through EVERY query inventoried from
# PostgresqlServer.java against BOTH nodes and asserts expected values:
#   select pg_is_in_recovery()                                   (Statement, :81)
#   select * from pg_stat_replication                            (Statement, :98)
#   select pg_current_wal_lsn() as wal_pos                       (Prepared, :118)
#   select pg_last_wal_replay_lsn() as wal_pos                   (Prepared, :134)
#   SELECT timeline_id FROM pg_control_checkpoint();             (Prepared, :150)
#   select usesuper from pg_user where usename='<user>';         (Prepared, :171)
#   select client_addr, TO_CHAR(...) as replay_lag, ...          (Prepared, :178)
#   select pg_wal_lsn_diff('<lsn>',pg_last_wal_replay_lsn()) ;   (Prepared, :207)
#   show synchronous_standby_names;                              (Prepared, :226)
#   select * from pg_stat_wal_receiver                           (Statement, :306)
#   SELECT conninfo FROM pg_stat_wal_receiver                    (Statement, :323)
#   select pg_tablespace_location(oid) AS location ...           (Prepared, :355)
# plus: unknown SQL must raise, close+reconnect must work.
#
# No Docker required. Exits non-zero on any failure. Stubs are always killed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUB="$ROOT/tools/fast-env/pgwire-stub.py"
FIXDIR="$ROOT/tools/fast-env/fixtures/healthy"
FIX1="$FIXDIR/pgwire-node1.json"
FIX2="$FIXDIR/pgwire-node2.json"

NODE1_HOST="127.0.10.11"; NODE1_PORT="5432"
NODE2_HOST="127.0.10.12"; NODE2_PORT="5433"

# Expected healthy values (literals from the SQL contract, NOT from the stub).
WAL="0/3000060"; TIMELINE="1"; USESUPER="t"
REPLICA_IP="127.0.10.12"; REPLAY_LAG="00:00:00"; APPNAME="fastenv_standby"; SYNCSTATE="async"
MASTER_IP="127.0.10.11"; MASTER_PORT="5432"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "OK: $*"; }

[ -f "$STUB" ] || fail "pgwire stub missing at $STUB"
[ -f "$FIX1" ] || fail "fixture missing at $FIX1"
[ -f "$FIX2" ] || fail "fixture missing at $FIX2"
command -v python3 >/dev/null || fail "python3 not found"
command -v javac >/dev/null || fail "javac not found"
command -v java >/dev/null || fail "java not found"

# 0. All fixture files must be valid JSON (acceptance criterion).
python3 - "$FIXDIR" <<'EOF'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1])
files = sorted(p for p in d.rglob("*.json"))
assert files, "no fixture JSON files found"
for p in files:
    json.load(open(p))
print("OK: %d fixture JSON files valid" % len(files))
EOF

# 1. Locate the real PostgreSQL JDBC driver jar (the app's own dependency).
# ADR-0001 gate: only the application's actual JDBC driver proves the stub.
# A psycopg fallback must never pass this script.
JDBC_JAR="${PG_JDBC_JAR:-}"
if [ -z "$JDBC_JAR" ]; then
  JDBC_JAR="$(ls -t ~/.m2/repository/org/postgresql/postgresql/*/postgresql-*.jar 2>/dev/null | grep -v sources | grep -v javadoc | head -n 1 || true)"
fi
if [ -z "${JDBC_JAR:-}" ] || [ ! -f "$JDBC_JAR" ]; then
  if [ -x "$ROOT/mvnw" ] && [ -f "$ROOT/app/pom.xml" ]; then
    echo "JDBC jar not in ~/.m2; trying ./mvnw dependency:build-classpath ..." >&2
    JDBC_JAR="$("$ROOT/mvnw" -q -f "$ROOT/app/pom.xml" dependency:build-classpath -Dmdep.outputFile=/dev/stdout 2>/dev/null \
      | tr ':' '\n' | grep -m1 'postgresql.*\.jar$' || true)"
  fi
fi
if [ -z "${JDBC_JAR:-}" ] || [ ! -f "$JDBC_JAR" ]; then
  fail "no PostgreSQL JDBC jar found (looked in PG_JDBC_JAR, ~/.m2, and via ./mvnw dependency:build-classpath); refusing psycopg fallback per ADR-0001 — resolve the app's JDBC driver and re-run"
fi
pass "JDBC jar: $JDBC_JAR"

# 2. Start one stub process per node tuple.
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT
python3 "$STUB" --host "$NODE1_HOST" --port "$NODE1_PORT" --fixture "$FIX1" &
PIDS+=($!)
python3 "$STUB" --host "$NODE2_HOST" --port "$NODE2_PORT" --fixture "$FIX2" &
PIDS+=($!)

wait_for_port() {
  local host="$1" port="$2" i
  for i in $(seq 1 100); do
    if python3 -c "import socket,sys; s=socket.create_connection(('$host',$port),timeout=0.2); s.close()" 2>/dev/null; then
      return 0
    fi
    # Bail out early if a stub died.
    for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null || fail "pgwire stub (pid $p) died during startup"; done
    sleep 0.1
  done
  fail "stub $host:$port not listening after 10s"
}
wait_for_port "$NODE1_HOST" "$NODE1_PORT"
wait_for_port "$NODE2_HOST" "$NODE2_PORT"
pass "both pgwire stubs listening"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; cleanup' EXIT

# 3. Real-JDBC proof: compile and run a Java program using the app's driver.
cat > "$WORK/TestFastEnvJdbc.java" <<'EOF'
import java.sql.*;
import java.util.Properties;
public class TestFastEnvJdbc {
  static int failures = 0;
  static void check(boolean cond, String label) {
    System.out.println((cond ? "  ok   " : "  FAIL ") + label);
    if (!cond) failures++;
  }
  public static void main(String[] a) throws Exception {
    // host port recovery(t/f) replRows wal timeline usesuper projClient projReplay projApp projSync recvRows connHost connPort
    String host = a[0]; int port = Integer.parseInt(a[1]);
    boolean recovery = a[2].equals("t");
    int replRows = Integer.parseInt(a[3]);
    String wal = a[4], tl = a[5], sup = a[6];
    String pClient = a[7], pReplay = a[8], pApp = a[9], pSync = a[10];
    int recvRows = Integer.parseInt(a[11]);
    String cHost = a[12], cPort = a[13];
    String url = "jdbc:postgresql://" + host + ":" + port + "/postgres";
    Properties props = new Properties();
    props.setProperty("user", "bfmuser");
    props.setProperty("password", "fastenv-dev-only");
    props.setProperty("connectTimeout", "5");
    props.setProperty("socketTimeout", "10");
    // NOTE: no sslmode set -> driver default (prefer) hits SSLRequest first,
    // proving the stub's SSL-negotiation path (must answer 'N', then startup).
    Connection c = DriverManager.getConnection(url, props);
    System.out.println("connected " + host + ":" + port);
    Statement st = c.createStatement();
    ResultSet rs = st.executeQuery("select pg_is_in_recovery()");
    rs.next(); check(rs.getBoolean(1) == recovery, "pg_is_in_recovery()=" + recovery);
    rs = st.executeQuery("select * from pg_stat_replication");
    int n = 0; while (rs.next()) n++;
    check(n == replRows, "pg_stat_replication rows=" + n + " expected=" + replRows);
    PreparedStatement ps = c.prepareStatement("select pg_current_wal_lsn() as wal_pos");
    ps.executeQuery(); rs = ps.getResultSet(); rs.next();
    check(wal.equals(rs.getString("wal_pos")), "pg_current_wal_lsn()=" + rs.getString("wal_pos"));
    ps = c.prepareStatement("select pg_last_wal_replay_lsn() as wal_pos");
    ps.executeQuery(); rs = ps.getResultSet(); rs.next();
    check(wal.equals(rs.getString("wal_pos")), "pg_last_wal_replay_lsn()=" + rs.getString("wal_pos"));
    ps = c.prepareStatement("SELECT timeline_id FROM pg_control_checkpoint();");
    ps.executeQuery(); rs = ps.getResultSet(); rs.next();
    check(tl.equals(rs.getString("timeline_id")), "timeline_id=" + rs.getString("timeline_id"));
    ps = c.prepareStatement("select usesuper from pg_user where usename='bfmuser';");
    ps.executeQuery(); rs = ps.getResultSet(); rs.next();
    check(sup.equals(rs.getString("usesuper")), "usesuper=" + rs.getString("usesuper"));
    ps = c.prepareStatement("select client_addr, TO_CHAR(replay_lag, 'HH24:MI:SS') as replay_lag, application_name, sync_state from pg_stat_replication;");
    ps.executeQuery(); rs = ps.getResultSet();
    n = 0; boolean projOk = true;
    while (rs.next()) {
      n++;
      if (!pClient.isEmpty()) {
        projOk = projOk && pClient.equals(rs.getString("client_addr"))
            && pReplay.equals(rs.getString("replay_lag"))
            && pApp.equals(rs.getString("application_name"))
            && pSync.equals(rs.getString("sync_state"));
      }
    }
    check(n == (pClient.isEmpty() ? 0 : 1) && projOk, "replay-lag projection rows=" + n);
    ps = c.prepareStatement("select pg_wal_lsn_diff('" + wal + "',pg_last_wal_replay_lsn()) ;");
    ps.executeQuery(); rs = ps.getResultSet();
    double d = -1; while (rs.next()) d = Double.parseDouble(rs.getString("pg_wal_lsn_diff"));
    check(d == 0.0, "pg_wal_lsn_diff=" + d);
    ps = c.prepareStatement("show synchronous_standby_names;");
    ps.executeQuery(); rs = ps.getResultSet();
    check(rs.next(), "show synchronous_standby_names returns a row");
    rs = st.executeQuery("select * from pg_stat_wal_receiver");
    n = 0; while (rs.next()) n++;
    check(n == recvRows, "pg_stat_wal_receiver rows=" + n + " expected=" + recvRows);
    rs = st.executeQuery("SELECT conninfo FROM pg_stat_wal_receiver");
    n = 0; boolean connOk = cHost.isEmpty();
    while (rs.next()) {
      n++;
      String ci = rs.getString("conninfo");
      if (!cHost.isEmpty()) connOk = ci.contains("host=" + cHost) && ci.contains("port=" + cPort);
    }
    check(cHost.isEmpty() ? n == 0 : (n > 0 && connOk), "conninfo host/port (rows=" + n + ")");
    ps = c.prepareStatement("select pg_tablespace_location(oid) AS location from pg_tablespace where spcname != 'pg_default' and spcname !='pg_global';");
    ps.executeQuery(); rs = ps.getResultSet();
    n = 0; while (rs.next()) n++;
    check(n == 0, "tablespaces zero rows");
    boolean gotErr = false;
    try { st.executeQuery("select bogus_xyz_fastenv_no_such_thing"); }
    catch (SQLException e) { gotErr = true; System.out.println("  ok   unknown SQL raised: " + e.getMessage()); }
    check(gotErr, "unknown SQL raises SQLException");
    c.close();
    c = DriverManager.getConnection(url, props);
    rs = c.createStatement().executeQuery("select pg_is_in_recovery()");
    rs.next(); check(rs.getBoolean(1) == recovery, "reconnect pg_is_in_recovery()=" + recovery);
    c.close();
    System.out.println(failures == 0 ? "NODE " + host + ":" + port + " ALL CHECKS PASSED"
                                     : "NODE " + host + ":" + port + " FAILURES=" + failures);
    if (failures > 0) System.exit(1);
  }
}
EOF

javac -cp "$JDBC_JAR" -d "$WORK" "$WORK/TestFastEnvJdbc.java" || fail "javac failed"
pass "JDBC proof program compiled"

timeout 60 java -cp "$WORK:$JDBC_JAR" TestFastEnvJdbc \
  "$NODE1_HOST" "$NODE1_PORT" f 1 "$WAL" "$TIMELINE" "$USESUPER" \
  "$REPLICA_IP" "$REPLAY_LAG" "$APPNAME" "$SYNCSTATE" 0 "" "" \
  || fail "JDBC proof failed against primary $NODE1_HOST:$NODE1_PORT"
timeout 60 java -cp "$WORK:$JDBC_JAR" TestFastEnvJdbc \
  "$NODE2_HOST" "$NODE2_PORT" t 0 "$WAL" "$TIMELINE" "$USESUPER" \
  "" "" "" "" 1 "$MASTER_IP" "$MASTER_PORT" \
  || fail "JDBC proof failed against replica $NODE2_HOST:$NODE2_PORT"

pass "test-pgwire-jdbc.sh: real-JDBC proof green on both nodes"
