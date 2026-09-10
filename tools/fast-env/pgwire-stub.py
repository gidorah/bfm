#!/usr/bin/env python3
"""Minimal PG-wire stub for the BFM fast environment (healthy scenario).

One process serves ONE node tuple: --host/--port select the bind address,
--fixture selects the per-node fixture file (tools/fast-env/fixtures/healthy/
pgwire-node{1,2}.json) that drives every canned answer.

Covers exactly the SQL inventory of PostgresqlServer.java plus the session
glue a real JDBC driver needs (SSLRequest -> 'N', trust startup, SET/SHOW,
BEGIN/COMMIT, EmptyQueryResponse, extended-protocol Parse/Bind/Describe/
Execute/Sync, Close, Terminate, reconnect). Anything else gets a clean
SQLSTATE XX000 error; the connection stays usable.

Stdlib only (asyncio + struct). No extra features.
"""
import argparse
import asyncio
import json
import re
import struct
import sys

BOOL = 16
INT4 = 23
TEXT = 25
FLOAT8 = 701
TIMESTAMPTZ = 1184

SHOW_DEFAULTS = {
    "server_version": None,  # filled from fixture
    "server_encoding": "UTF8",
    "client_encoding": "UTF8",
    "datestyle": "ISO, MDY",
    "timezone": "UTC",
    "standard_conforming_strings": "on",
    "integer_datetimes": "on",
    "transaction_isolation": "read committed",
    "application_name": "",
    "extra_float_digits": "1",
    "is_superuser": "on",
}

REPL_COLS = [
    ("pid", INT4), ("usename", TEXT), ("application_name", TEXT),
    ("client_addr", TEXT), ("client_hostname", TEXT),
    ("state", TEXT), ("sync_state", TEXT),
]

WALRCV_COLS = [
    ("pid", INT4), ("status", TEXT), ("receive_start_lsn", TEXT),
    ("receive_start_tli", INT4), ("written_lsn", TEXT), ("flushed_lsn", TEXT),
    ("received_tli", INT4), ("last_msg_send_time", TIMESTAMPTZ),
    ("last_msg_receipt_time", TIMESTAMPTZ), ("latest_end_lsn", TEXT),
    ("latest_end_time", TIMESTAMPTZ), ("slot_name", TEXT),
    ("sender_host", TEXT), ("sender_port", INT4), ("conninfo", TEXT),
]

GLUE_PREFIXES = (
    "set ", "reset ", "discard ", "deallocate ", "listen ", "unlisten ",
    "notify ", "close ", "fetch ", "move ", "savepoint ", "release ",
)
GLUE_EXACT = {"begin", "commit", "rollback", "start transaction", "end"}


def pack_msg(typ, payload):
    return typ + struct.pack("!i", len(payload) + 4) + payload


def row_desc(cols):
    out = [struct.pack("!h", len(cols))]
    for name, oid in cols:
        size = 1 if oid == BOOL else (4 if oid == INT4 else (8 if oid == FLOAT8 else -1))
        out.append(name.encode() + b"\x00" + struct.pack("!ihihih", 0, 0, oid, size, -1, 0))
    return pack_msg(b"T", b"".join(out))


def data_rows(rows):
    out = []
    for row in rows:
        cells = [struct.pack("!h", len(row))]
        for v in row:
            if v is None:
                cells.append(struct.pack("!i", -1))
            else:
                b = str(v).encode()
                cells.append(struct.pack("!i", len(b)) + b)
        out.append(pack_msg(b"D", b"".join(cells)))
    return b"".join(out)


def command_complete(tag):
    return pack_msg(b"C", tag.encode() + b"\x00")


def error_response(msg):
    body = (b"SERROR\x00VERROR\x00CXX000\x00M" + msg.encode()[:500]
            + b"\x00\x00")
    return pack_msg(b"E", body)


def norm(sql):
    return re.sub(r"\s+", " ", sql.strip().rstrip(";").strip().lower())


class Stub:
    def __init__(self, fixture):
        self.f = fixture
        self.is_primary = fixture.get("role", "primary") == "primary"
        self.in_recovery = "f" if self.is_primary else "t"

    def evaluate(self, sql):
        """-> ('rows', cols, rows, tag) | ('cmd', tag) | ('error', msg) | ('empty',)."""
        q = norm(sql)
        if not q:
            return ("empty",)
        f = self.f
        if "pg_is_in_recovery" in q:
            return ("rows", [("pg_is_in_recovery", BOOL)], [[self.in_recovery]], "SELECT 1")
        if "pg_stat_replication" in q and ("client_addr" in q or "replay_lag" in q):
            cols = [("client_addr", TEXT), ("replay_lag", TEXT),
                    ("application_name", TEXT), ("sync_state", TEXT)]
            rows = [[r["client_addr"], r["replay_lag"], r["application_name"], r["sync_state"]]
                    for r in f.get("replication", [])]
            return ("rows", cols, rows, "SELECT %d" % len(rows))
        if "pg_stat_replication" in q:
            rows = [["12345", self.peer_user, r["application_name"], r["client_addr"],
                     "", "streaming", r["sync_state"]]
                    for r in f.get("replication", [])]
            return ("rows", REPL_COLS, rows, "SELECT %d" % len(rows))
        if "pg_current_wal_lsn" in q or ("pg_last_wal_replay_lsn" in q and "pg_wal_lsn_diff" not in q):
            return ("rows", [("wal_pos", TEXT)], [[f.get("wal_lsn", "0/3000060")]], "SELECT 1")
        if "timeline_id" in q:
            return ("rows", [("timeline_id", INT4)], [[str(f.get("timeline_id", 1))]], "SELECT 1")
        if "usesuper" in q and "pg_user" in q:
            return ("rows", [("usesuper", BOOL)], [[f.get("usesuper", "t")]], "SELECT 1")
        if "pg_wal_lsn_diff" in q:
            return ("rows", [("pg_wal_lsn_diff", FLOAT8)], [["0"]], "SELECT 1")
        if "synchronous_standby_names" in q:
            return ("rows", [("synchronous_standby_names", TEXT)],
                    [[f.get("synchronous_standby_names", "")]], "SHOW 1")
        if "pg_stat_wal_receiver" in q and "conninfo" in q:
            ci = f.get("conninfo", "")
            rows = [[ci]] if ci else []
            return ("rows", [("conninfo", TEXT)], rows, "SELECT %d" % len(rows))
        if "pg_stat_wal_receiver" in q:
            ci = f.get("conninfo", "")
            if not ci:
                return ("rows", WALRCV_COLS, [], "SELECT 0")
            t = "2026-01-01 00:00:00+00"
            w = f.get("wal_lsn", "0/3000060")
            rows = [["12346", "streaming", w, "1", w, w, "1", t, t, w, t, "",
                     f.get("master_host", ""), f.get("master_port", ""), ci]]
            return ("rows", WALRCV_COLS, rows, "SELECT 1")
        if "pg_tablespace_location" in q:
            return ("rows", [("location", TEXT)], [], "SELECT 0")
        if q.startswith("show "):
            param = q[5:].strip()
            val = SHOW_DEFAULTS.get(param, "")
            if param == "server_version":
                val = f.get("server_version", "15.4")
            if param == "synchronous_standby_names":
                val = f.get("synchronous_standby_names", "")
            return ("rows", [(param, TEXT)], [[val]], "SHOW 1")
        m = re.match(r"select\s+(\d+)\s*$", q)
        if m:
            return ("rows", [("?column?", INT4)], [[m.group(1)]], "SELECT 1")
        if q in GLUE_EXACT or q.startswith(GLUE_PREFIXES):
            return ("cmd", q.split()[0].upper())
        return ("error", "unrecognized query (fast-env stub): %.120s" % sql.strip())


def read_cstring(buf, pos):
    end = buf.index(b"\x00", pos)
    return buf[pos:end].decode(), end + 1


class Conn:
    def __init__(self, stub, reader, writer):
        self.stub = stub
        self.reader = reader
        self.writer = writer
        self.stmts = {}
        self.portals = {}
        self.outbox = []
        self.discard_until_sync = False

    def result_messages(self, evaluation, describe_only=False):
        kind = evaluation[0]
        if kind == "empty":
            return [pack_msg(b"I", b"")]
        if kind == "cmd":
            return [command_complete(evaluation[1])]
        if kind == "error":
            return [error_response(evaluation[1])]
        _, cols, rows, tag = evaluation
        msgs = [row_desc(cols)]
        if not describe_only:
            msgs.append(data_rows(rows))
            msgs.append(command_complete(tag))
        return msgs

    async def run(self):
        try:
            await self.handshake()
        except (asyncio.IncompleteReadError, ConnectionResetError):
            return
        self.stub.peer_user = getattr(self, "peer_user", "bfmuser")
        try:
            while True:
                typ = await self.reader.readexactly(1)
                ln = struct.unpack("!i", await self.reader.readexactly(4))[0]
                payload = await self.reader.readexactly(ln - 4) if ln > 4 else b""
                if typ == b"X":
                    return
                elif typ == b"Q":
                    self.handle_simple(payload[:-1].decode(errors="replace") if payload.endswith(b"\x00") else payload.decode(errors="replace"))
                    self.flush(with_ready=True)
                elif typ == b"S":
                    self.discard_until_sync = False
                    self.flush(with_ready=True)
                elif typ == b"H":
                    self.flush(with_ready=False)
                elif self.discard_until_sync:
                    continue
                elif typ == b"P":
                    sname, p = read_cstring(payload, 0)
                    query, p = read_cstring(payload, p)
                    if ";" in query.strip().rstrip(";"):
                        self.outbox.append(error_response("multiple statements in prepared statement"))
                    else:
                        self.stmts[sname] = query
                        self.outbox.append(pack_msg(b"1", b""))
                elif typ == b"B":
                    pname, p = read_cstring(payload, 0)
                    sname, _ = read_cstring(payload, p)
                    self.portals[pname] = {"query": self.stmts.get(sname, ""), "described": False}
                    self.outbox.append(pack_msg(b"2", b""))
                elif typ == b"D":
                    kind = chr(payload[0])
                    name, _ = read_cstring(payload, 1)
                    query = self.stmts.get(name, "") if kind == "S" else self.portals.get(name, {}).get("query", "")
                    ev = self.stub.evaluate(query)
                    if ev[0] in ("rows",):
                        self.outbox.append(row_desc(ev[1]))
                    elif ev[0] == "error":
                        self.outbox.append(error_response(ev[1]))
                        self.discard_until_sync = True
                    else:
                        self.outbox.append(pack_msg(b"n", b""))
                    if kind == "P" and name in self.portals:
                        self.portals[name]["described"] = True
                elif typ == b"E":
                    pname, _ = read_cstring(payload, 0)
                    portal = self.portals.get(pname)
                    if portal is None:
                        self.outbox.append(error_response("unknown portal %r" % pname))
                        self.discard_until_sync = True
                        continue
                    ev = self.stub.evaluate(portal["query"])
                    if ev[0] == "error":
                        self.outbox.append(error_response(ev[1]))
                        self.discard_until_sync = True
                        continue
                    if not portal["described"]:
                        self.outbox += self.result_messages(ev, describe_only=False)
                        portal["described"] = True
                    else:
                        if ev[0] == "empty":
                            self.outbox.append(pack_msg(b"I", b""))
                        elif ev[0] == "cmd":
                            self.outbox.append(command_complete(ev[1]))
                        else:
                            _, _, rows, tag = ev
                            self.outbox.append(data_rows(rows))
                            self.outbox.append(command_complete(tag))
                elif typ == b"C":
                    kind = chr(payload[0])
                    name, _ = read_cstring(payload, 1)
                    if kind == "S":
                        self.stmts.pop(name, None)
                    else:
                        self.portals.pop(name, None)
                    self.outbox.append(pack_msg(b"3", b""))
                # CopyData/CopyDone/CopyFail and anything else: ignored (not in inventory).
        except (asyncio.IncompleteReadError, ConnectionResetError):
            return
        finally:
            try:
                self.writer.close()
            except Exception:
                pass

    def handle_simple(self, sql):
        parts = sql.split(";")
        if all(not p.strip() for p in parts):
            self.outbox.append(pack_msg(b"I", b""))
            return
        for p in parts:
            if not p.strip():
                continue
            self.outbox += self.result_messages(self.stub.evaluate(p))

    def flush(self, with_ready):
        if self.outbox:
            self.writer.writelines(self.outbox)
            self.outbox = []
        if with_ready:
            self.writer.write(pack_msg(b"Z", b"I"))

    async def handshake(self):
        while True:
            ln = struct.unpack("!i", await self.reader.readexactly(4))[0]
            rest = await self.reader.readexactly(ln - 4)
            code = struct.unpack("!i", rest[:4])[0] if len(rest) >= 4 else 0
            if ln == 8 and code in (80877103, 80877104):
                self.writer.write(b"N")  # no SSL/GSSAPI: driver falls back to plaintext
                await self.writer.drain()
                continue
            params = rest[4:].split(b"\x00")
            kv = {}
            for i in range(0, len(params) - 1, 2):
                if params[i]:
                    kv[params[i].decode(errors="replace")] = params[i + 1].decode(errors="replace") if i + 1 < len(params) else ""
            self.peer_user = kv.get("user", "bfmuser")
            self.stub.peer_user = self.peer_user
            f = self.stub.f
            out = [pack_msg(b"R", struct.pack("!i", 0))]
            for k, v in [
                ("server_version", f.get("server_version", "15.4")),
                ("server_encoding", "UTF8"),
                ("client_encoding", "UTF8"),
                ("DateStyle", "ISO, MDY"),
                ("TimeZone", "UTC"),
                ("integer_datetimes", "on"),
                ("standard_conforming_strings", "on"),
                ("is_superuser", "on"),
                ("session_authorization", self.peer_user),
            ]:
                out.append(pack_msg(b"S", k.encode() + b"\x00" + v.encode() + b"\x00"))
            out.append(pack_msg(b"K", struct.pack("!ii", 12345, 67890)))
            out.append(pack_msg(b"Z", b"I"))
            self.writer.writelines(out)
            await self.writer.drain()
            return


async def serve(host, port, fixture):
    stub = Stub(fixture)

    async def on_conn(reader, writer):
        await Conn(stub, reader, writer).run()

    server = await asyncio.start_server(on_conn, host, port)
    print("pgwire-stub role=%s listening on %s:%d" % (fixture.get("role"), host, port), flush=True)
    async with server:
        await server.serve_forever()


def main():
    ap = argparse.ArgumentParser(description="minimal PG-wire stub (fast-env healthy scenario)")
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", required=True, type=int)
    ap.add_argument("--fixture", required=True)
    args = ap.parse_args()
    with open(args.fixture) as fh:
        fixture = json.load(fh)
    try:
        asyncio.run(serve(args.host, args.port, fixture))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
