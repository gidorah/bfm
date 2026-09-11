#!/usr/bin/env python3
"""Compatible MiniPG agent for the BFM live environment (issue #18, part B).

Runs next to PostgreSQL inside each ``bfm-live`` node container
(``live-pg1``/``live-pg2``) and implements the exact MiniPG HTTP surface BFM
calls (see ``app/src/main/java/com/bisoft/bfm/helper/MinipgAccessUtil.java``):

* ``MinipgAccessUtil.status()`` sends the ``Authorization`` header preemptively
  (java.net.http) on ``GET /minipg/pgstatus``.
* Every other op goes through Apache HttpClient ``CredentialsProvider``, i.e. a
  401-challenge flow: the agent MUST answer missing/invalid credentials with
  ``401`` + ``WWW-Authenticate: Basic`` or those calls can never authenticate.

Every op returns HTTP 200 with a short text body within seconds so BFM's
5s/7s/11s loops never block on this agent; failures are reported as
``ERROR: ...`` bodies (BFM gates on bodies for rewind/rebaseUp/setsync and
falls back accordingly). All activity logs to stdout (``docker logs``).

Real ops against the local PG (``PGDATA=/var/lib/postgresql/data``,
``pg_ctl`` for server control, ``psql -U bfm`` for SQL)::

* promote  -> ``pg_ctl promote`` (fallback ``SELECT pg_promote()``) +
  clear ``synchronous_standby_names`` + reload.
* rewind   -> stop PG, ``pg_rewind --source-server`` against the supplied
  master, write ``standby.signal``/``primary_conninfo``, start.
* rebaseUp -> stop, wipe the data dir contents (``PG_VERSION`` must exist;
  the directory itself is kept), ``pg_basebackup -R`` from the supplied
  master, start.
* start/stop -> ``pg_ctl``; checkpoint -> ``CHECKPOINT`` (best effort on a
  standby); setsync/setasync -> ``ALTER SYSTEM`` + ``pg_reload_conf()``.
* vip-up/vip-down -> write/delete the marker file ``/tmp/bfm-vip-holder``
  holding the node's host-mapped loopback IP (``NODE_IP``, e.g. 127.0.10.11;
  ``NODE_NAME`` fallback when unset). Best-effort real-marker semantics: a
  real VIP needs a VM layer, which is explicitly out of scope for the live
  environment; checkvip reports the holder (``VIP:HOLDER=<ip>``/``VIP:NONE``).
* updatepgpass -> merges entries into ``~postgres/.pgpass`` (0600).
  clearAutoConf -> only if safe: on a primary, drop a stale ``standby.signal``
  and reset ``primary_conninfo``; on a standby, touch nothing.
  cleanOldBackups -> prune stale local backup artefacts (this image keeps no
  server-side backups; ``pg_basebackup`` streams directly), else OK.
  fixappname/setappname/pre-so/post-so -> cheap real equivalent where trivial
  (record ``application_name``; refresh a standby's ``primary_conninfo``
  application_name + reload), else OK quickly.

Host-mapped endpoint translation: BFM addresses nodes by their host-published
endpoints (``127.0.10.11:5432``, ``127.0.10.12:5433``), which are NOT dialable
from inside a container. The agent translates those two loopback-adjacent IPs
to the compose-network hostnames (``live-pg1``/``live-pg2``, container PG port
5432). Anything else passes through unchanged. This is topology-derived, not
scenario-specific: no scenario logic lives in this image.

``kill-primary`` support falls out of the packaging: PG + agent share one
service, so ``docker stop bfm-live-pg1`` kills both; BFM promotes pg2 via its
agent and ``docker start`` brings pg1 back for BFM-driven rewind/rejoin.

Stdlib only. ``python3 minipg-agent.py --self-check`` runs the offline
self-check (route table + auth-challenge + translation + body parsing, no PG
or sockets needed).
"""

import base64
import binascii
import glob
import hmac
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Stdlib only (no third-party dependencies).

# --------------------------------------------------------------------------
# Configuration (env overridable; defaults are the disposable test-only creds)
# --------------------------------------------------------------------------

MINIPG_USER = os.environ.get("MINIPG_USER", "bfm")
MINIPG_PASSWORD = os.environ.get("MINIPG_PASSWORD", "bfm")
MINIPG_PORT = int(os.environ.get("MINIPG_PORT", "7779"))
PGDATA = os.environ.get("PGDATA", "/var/lib/postgresql/data")
PGUSER = os.environ.get("PGUSER", "bfm")
PGDATABASE = os.environ.get("PGDATABASE", "postgres")
PGPORT = os.environ.get("PGPORT", "5432")
PGSOCKET = os.environ.get("PGSOCKET", "/var/run/postgresql")
NODE_NAME = os.environ.get("NODE_NAME", "") or socket.gethostname()
# Holder address written to the VIP marker by vip-up (the node's host-mapped
# loopback IP, e.g. 127.0.10.11; live-env.sh vip_on greps checkvip for it).
NODE_IP = os.environ.get("NODE_IP", "")
VIP_FILE = os.environ.get("VIP_FILE", "/tmp/bfm-vip-holder")
APPNAME_FILE = os.environ.get("APPNAME_FILE", "/tmp/bfm-appname")
# Written by docker/entrypoint.sh from the compose `command:` block (the PG
# `-c` flags); read back on every server start so agent-driven restarts
# (stop/start/rewind/rebaseUp) reuse the exact flags PG booted with.
PG_OPTS_FILE = os.environ.get("PG_OPTS_FILE", "/var/lib/postgresql/bfm-pg-opts")
PG_LOG_FILE = os.path.join(PGDATA, "log", "postgresql.log")

PG_BIN_DIR = "/usr/lib/postgresql/16/bin"
# Host-mapped loopback endpoints BFM uses -> compose-network (hostname, port).
# Inside containers PG always listens on 5432 (pg2's host-side 5433 is only a
# publish mapping), so translated ports are forced to 5432.
HOST_ENDPOINT_MAP = {
    "127.0.10.11": ("live-pg1", "5432"),
    "127.0.10.12": ("live-pg2", "5432"),
}

STATUS_OK = "OK"
START_OK = "done - server started"

GET_OPS = (
    "pgstatus",
    "status",
    "checkpoint",
    "start",
    "stop",
    "vip-up",
    "vip-down",
    "checkvip",
    "pre-so",
    "fixappname",
    "clearAutoConf",
    "cleanOldBackups",
)
POST_OPS = (
    "promote",
    "rewind",
    "rebaseUp",
    "post-so",
    "setappname",
    "setsync",
    "setasync",
    "updatepgpass",
)


def log(msg):
    """Log to stdout (surfaced via `docker logs`)."""
    print("[minipg-agent] %s" % msg, flush=True)


def binpath(name):
    """Resolve a PG binary; prefer PATH, fall back to the PG bindir."""
    found = shutil.which(name)
    if found:
        return found
    return os.path.join(PG_BIN_DIR, name)


def default_env(extra=None):
    env = dict(os.environ)
    env.setdefault("PGDATA", PGDATA)
    env.setdefault("PGUSER", PGUSER)
    if extra:
        env.update(extra)
    return env


def run(cmd, timeout=30, extra_env=None):
    """Run a command; return the CompletedProcess (never raises on rc)."""
    log("+ %s" % " ".join(cmd))
    try:
        return subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=default_env(extra_env),
        )
    except subprocess.TimeoutExpired:
        log("TIMEOUT after %ss: %s" % (timeout, " ".join(cmd)))
        raise


def pg_ctl(*args, timeout=40):
    return run([binpath("pg_ctl"), "-D", PGDATA] + list(args), timeout=timeout)


def psql_sql(sql, timeout=20, dbname=None):
    """Run one SQL statement as the superuser over the local socket."""
    proc = run(
        [
            binpath("psql"),
            "-h",
            PGSOCKET,
            "-p",
            str(PGPORT),
            "-U",
            PGUSER,
            "-d",
            dbname or PGDATABASE,
            "-v",
            "ON_ERROR_STOP=1",
            "-tAc",
            sql,
        ],
        timeout=timeout,
    )
    if proc.returncode != 0:
        raise RuntimeError("psql failed: %s" % (proc.stderr.strip() or proc.stdout.strip()))
    return proc.stdout.strip()


def pg_is_in_recovery():
    return psql_sql("SELECT pg_is_in_recovery();") == "t"


def pg_server_running():
    return pg_ctl("status", timeout=10).returncode == 0


def pg_extra_opts():
    """Extra `postgres -c ...` flags saved by the entrypoint (may be empty)."""
    try:
        with open(PG_OPTS_FILE) as fh:
            return fh.read().strip()
    except OSError:
        return ""


def pg_start():
    ensure_logdir()
    # pg_basebackup does not chmod the target (unlike initdb); PG refuses to
    # start on a group/world-accessible data dir. Self-heal on every start so
    # agent-driven restarts never trip over it either.
    try:
        os.chmod(PGDATA, 0o700)
    except OSError:
        pass
    cmd = ["-l", PG_LOG_FILE, "-w", "-t", "60", "start"]
    opts = pg_extra_opts()
    if opts:
        cmd += ["-o", opts]
    return pg_ctl(*cmd, timeout=90)


def ensure_logdir():
    os.makedirs(os.path.dirname(PG_LOG_FILE), exist_ok=True)


def ensure_hba():
    """Re-append the disposable trust snippet if it went missing.

    pg_hba.conf lives inside PGDATA, so a rebaseUp wipe restores the master's
    copy via pg_basebackup (which already carries the snippet); this is only
    belt-and-braces for a hand-built data dir.
    """
    snippet = "/opt/bfm/docker/pg_hba.live.conf"
    hba = os.path.join(PGDATA, "pg_hba.conf")
    marker = "bfm-live-trust-BEGIN"
    try:
        with open(hba) as fh:
            if marker in fh.read():
                return
        with open(snippet) as fh:
            extra = fh.read()
        with open(hba, "a") as fh:
            fh.write("\n" + extra)
        log("pg_hba: appended disposable trust snippet (DO NOT use in production)")
        if pg_server_running():
            pg_ctl("reload", timeout=15)
    except OSError as exc:
        log("pg_hba: ensure failed: %s" % exc)


def sql_quote_literal(value):
    return "'" + value.replace("'", "''") + "'"


def sql_quote_ident(value):
    return '"' + value.replace('"', '""') + '"'


# --------------------------------------------------------------------------
# Auth: preemptive Basic accepted, missing/invalid -> 401 + challenge
# --------------------------------------------------------------------------

def check_auth(auth_header, exp_user, exp_password):
    """True iff `auth_header` carries valid Basic creds (preemptive OK)."""
    if not auth_header:
        return False
    scheme, _, blob = auth_header.partition(" ")
    if scheme.lower() != "basic" or not blob.strip():
        return False
    try:
        decoded = base64.b64decode(blob.strip(), validate=True).decode("utf-8")
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return False
    user, sep, password = decoded.partition(":")
    if not sep:
        return False
    return hmac.compare_digest(user, exp_user) and hmac.compare_digest(password, exp_password)


def unauthorized_headers():
    return {"WWW-Authenticate": 'Basic realm="minipg"'}


# --------------------------------------------------------------------------
# Host-mapped endpoint translation (BFM host view -> container network view)
# --------------------------------------------------------------------------

def translate_endpoint(host, port):
    """Map a BFM-supplied (host, port) to a dialable (host, port).

    The two loopback-adjacent publish IPs become compose hostnames on the
    container-internal PG port; anything else passes through (default port
    5432 when blank).
    """
    host = (host or "").strip()
    port = (port or "").strip() or "5432"
    if host in HOST_ENDPOINT_MAP:
        return HOST_ENDPOINT_MAP[host]
    return (host, port)


# --------------------------------------------------------------------------
# Request body parsing (BFM sends JSON for some ops, raw text for others)
# --------------------------------------------------------------------------

def parse_json_body(raw):
    if not raw or not raw.strip():
        return {}
    try:
        data = json.loads(raw)
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def master_from_rewind(data):
    host, port = translate_endpoint(data.get("masterIp", ""), data.get("port", ""))
    return {
        "host": host,
        "port": port,
        "user": data.get("user") or data.get("repUser") or "bfm",
        "password": data.get("password") or data.get("repPassword") or "",
    }


def master_from_rebase(data):
    host, port = translate_endpoint(data.get("masterIp", ""), data.get("masterPort", ""))
    return {
        "host": host,
        "port": port,
        "user": data.get("repUser") or data.get("user") or "bfm",
        "password": data.get("repPassword") or data.get("password") or "",
    }


def build_sync_sql(app_name):
    return "ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (%s)';" % sql_quote_ident(app_name)


# --------------------------------------------------------------------------
# Ops (each returns a short text body; HTTP status is always 200 here)
# --------------------------------------------------------------------------

def err(text):
    text = " ".join(str(text).split())[:300]
    log("ERROR: %s" % text)
    return "ERROR: %s" % text


def op_pgstatus():
    return STATUS_OK


def op_status():
    # BFM's UI compares the trimmed body to "OK" (sync-toggle + slave rows).
    return STATUS_OK


def op_checkpoint():
    try:
        psql_sql("CHECKPOINT;", timeout=30)
        return STATUS_OK
    except Exception as exc:
        # A standby may refuse CHECKPOINT; BFM only logs the result.
        log("checkpoint best-effort: %s" % exc)
        return STATUS_OK


def op_start():
    try:
        if pg_server_running():
            return START_OK + " (already running)"
        proc = pg_start()
        if proc.returncode == 0:
            return START_OK
        return err("pg_ctl start failed: %s" % (proc.stderr.strip() or proc.stdout.strip()))
    except Exception as exc:
        return err(exc)


def op_stop():
    try:
        if not pg_server_running():
            return STATUS_OK + " (already stopped)"
        proc = pg_ctl("-m", "fast", "-t", "30", "-w", "stop", timeout=60)
        if proc.returncode == 0:
            return STATUS_OK
        return err("pg_ctl stop failed: %s" % (proc.stderr.strip() or proc.stdout.strip()))
    except Exception as exc:
        return err(exc)


def promote_verdict(pg_ctl_rc, pg_ctl_detail, pg_promote_detail, in_recovery, recovery_error=""):
    """Pure promote verdict: map attempt outputs + recovery state to a body.

    `in_recovery`: False=primary, True=still standby, None=verify unreachable.
    Returns ``STATUS_OK`` (or ``STATUS_OK`` + note) only when the node is
    actually primary; otherwise a non-OK ``ERROR: ...`` body containing both
    attempt outputs. No I/O, no logging (caller logs); unit-testable.
    """
    def _clean(text):
        return " ".join(str(text or "").split())[:300]

    ctl = _clean(pg_ctl_detail)
    prm = _clean(pg_promote_detail) or "not attempted"
    if in_recovery is False:
        if pg_ctl_rc != 0:
            return STATUS_OK + " (already primary)"
        return STATUS_OK
    if in_recovery is None:
        rec = _clean(recovery_error) or "unreachable"
        body = (
            "promote failed: local PG unreachable after promote attempt "
            "(pg_ctl rc=%s: %s; pg_promote: %s; verify: %s)"
            % (pg_ctl_rc, ctl or "no output", prm, rec)
        )
        return "ERROR: %s" % body[:300]
    body = (
        "promote failed: still in recovery after promote attempt "
        "(pg_ctl rc=%s: %s; pg_promote: %s)"
        % (pg_ctl_rc, ctl or "no output", prm)
    )
    return "ERROR: %s" % body[:300]


def op_promote(data):
    try:
        proc = pg_ctl("-w", "-t", "30", "promote", timeout=60)
        pg_ctl_detail = proc.stderr.strip() or proc.stdout.strip()
        if proc.returncode != 0:
            log("pg_ctl promote: %s; trying SELECT pg_promote()" % pg_ctl_detail)
            try:
                out = psql_sql("SELECT pg_promote(true, 30);", timeout=45)
                log("pg_promote() -> %s" % out)
                pg_promote_detail = out
            except Exception as exc:
                log("pg_promote() failed (probably already primary): %s" % exc)
                pg_promote_detail = "failed: %s" % exc
        else:
            pg_promote_detail = ""
        standby = os.path.join(PGDATA, "standby.signal")
        if os.path.exists(standby):
            os.remove(standby)
        try:
            psql_sql("ALTER SYSTEM RESET synchronous_standby_names;", timeout=15)
            psql_sql("SELECT pg_reload_conf();", timeout=15)
        except Exception as exc:
            log("promote sync-clear best-effort: %s" % exc)
        # Verify-then-report: only claim OK when actually primary.
        try:
            in_recovery = pg_is_in_recovery()
            recovery_error = ""
        except Exception as exc:
            in_recovery = None
            recovery_error = str(exc)
        body = promote_verdict(
            proc.returncode, pg_ctl_detail, pg_promote_detail, in_recovery, recovery_error
        )
        if body.startswith("ERROR"):
            log("ERROR: %s" % body)
        return body
    except Exception as exc:
        return err(exc)


def rewrite_primary_conninfo(host, port, user, app_name):
    """Replace the primary_conninfo line in postgresql.auto.conf."""
    auto = os.path.join(PGDATA, "postgresql.auto.conf")
    try:
        with open(auto) as fh:
            lines = fh.read().splitlines()
    except OSError:
        lines = []
    lines = [ln for ln in lines if not ln.lstrip().startswith("primary_conninfo")]
    conninfo = "user=%s host=%s port=%s application_name=%s" % (user, host, port, app_name)
    lines.append("primary_conninfo = %s" % sql_quote_literal(conninfo))
    with open(auto, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    try:
        os.chmod(auto, 0o600)
    except OSError:
        pass


def op_rewind(data):
    try:
        master = master_from_rewind(data)
        if not master["host"]:
            return err("rewind: missing masterIp")
        log("rewind from %s:%s as %s" % (master["host"], master["port"], master["user"]))
        try:
            if pg_server_running():
                pg_ctl("-m", "fast", "-t", "30", "-w", "stop", timeout=60)
        except Exception as exc:
            log("rewind pre-stop best-effort: %s" % exc)
        source = "host=%s port=%s user=%s dbname=postgres" % (
            master["host"],
            master["port"],
            master["user"],
        )
        proc = run(
            [binpath("pg_rewind"), "--source-server=%s" % source, "--target-pgdata=%s" % PGDATA],
            timeout=180,
            extra_env={"PGPASSWORD": master["password"]},
        )
        if proc.returncode != 0:
            detail = proc.stderr.strip() or proc.stdout.strip()
            # Leave PG stopped; BFM falls back to rebaseUp on a non-OK body.
            return err("pg_rewind failed: %s" % detail)
        open(os.path.join(PGDATA, "standby.signal"), "a").close()
        rewrite_primary_conninfo(master["host"], master["port"], master["user"], NODE_NAME)
        ensure_hba()
        started = pg_start()
        if started.returncode != 0:
            return err(
                "rewound but pg_ctl start failed: %s"
                % (started.stderr.strip() or started.stdout.strip())
            )
        return STATUS_OK
    except Exception as exc:
        return err(exc)


def wipe_pgdata():
    version = os.path.join(PGDATA, "PG_VERSION")
    if not os.path.isfile(version):
        raise RuntimeError("refusing wipe: %s missing (not a data dir)" % version)
    for entry in os.listdir(PGDATA):
        path = os.path.join(PGDATA, entry)
        if os.path.islink(path) or os.path.isfile(path):
            os.remove(path)
        elif os.path.isdir(path):
            shutil.rmtree(path)


def op_rebaseup(data):
    try:
        master = master_from_rebase(data)
        if not master["host"]:
            return err("rebaseUp: missing masterIp")
        log(
            "rebaseUp from %s:%s as %s"
            % (master["host"], master["port"], master["user"])
        )
        try:
            if pg_server_running():
                pg_ctl("-m", "fast", "-t", "30", "-w", "stop", timeout=60)
        except Exception as exc:
            log("rebaseUp pre-stop best-effort: %s" % exc)
        try:
            wipe_pgdata()
        except Exception as exc:
            return err(exc)
        proc = run(
            [
                binpath("pg_basebackup"),
                "-R",
                "-h",
                master["host"],
                "-p",
                master["port"],
                "-U",
                master["user"],
                "-D",
                PGDATA,
                "-c",
                "fast",
            ],
            timeout=300,
            extra_env={"PGPASSWORD": master["password"]},
        )
        if proc.returncode != 0:
            return err(
                "pg_basebackup failed: %s" % (proc.stderr.strip() or proc.stdout.strip())
            )
        inject_standby_appname()
        ensure_hba()
        started = pg_start()
        if started.returncode != 0:
            return err(
                "basebackup ok but pg_ctl start failed: %s"
                % (started.stderr.strip() or started.stdout.strip())
            )
        return STATUS_OK
    except Exception as exc:
        return err(exc)


def inject_standby_appname(app_name=None):
    """Set application_name on an existing primary_conninfo (best effort)."""
    auto = os.path.join(PGDATA, "postgresql.auto.conf")
    try:
        with open(auto) as fh:
            content = fh.read()
    except OSError:
        return
    if "primary_conninfo" not in content or "application_name" in content:
        return
    content = content.replace(
        "primary_conninfo = '", "primary_conninfo = 'application_name=%s " % (app_name or NODE_NAME), 1
    )
    try:
        with open(auto, "w") as fh:
            fh.write(content)
    except OSError as exc:
        log("inject application_name failed: %s" % exc)


def op_vip_up():
    try:
        with open(VIP_FILE, "w") as fh:
            fh.write((NODE_IP or NODE_NAME) + "\n")
        return STATUS_OK + " (vip up on %s)" % (NODE_IP or NODE_NAME)
    except Exception as exc:
        return err(exc)


def op_vip_down():
    try:
        if os.path.exists(VIP_FILE):
            os.remove(VIP_FILE)
        return STATUS_OK + " (vip down)"
    except Exception as exc:
        return err(exc)


def op_checkvip():
    try:
        with open(VIP_FILE) as fh:
            holder = fh.read().strip()
        if holder:
            return "VIP:HOLDER=%s" % holder
        return "VIP:NONE"
    except OSError:
        return "VIP:NONE"


def op_pre_so():
    return STATUS_OK


def op_post_so(data):
    return STATUS_OK


def record_appname(name):
    try:
        with open(APPNAME_FILE, "w") as fh:
            fh.write((name or NODE_NAME) + "\n")
    except OSError as exc:
        log("record application_name failed: %s" % exc)


def refresh_standby_appname(name):
    """Point a standby's walreceiver at `name` (best effort, no restart)."""
    try:
        if not pg_server_running() or not pg_is_in_recovery():
            return
        auto = os.path.join(PGDATA, "postgresql.auto.conf")
        with open(auto) as fh:
            content = fh.read()
        if "primary_conninfo" not in content:
            return
        new_content, n = re.subn(
            r"application_name\s*=\s*[^\s']+",
            "application_name=%s" % name,
            content,
        )
        if n == 0:
            new_content = content.replace(
                "primary_conninfo = '",
                "primary_conninfo = 'application_name=%s " % name,
                1,
            )
        with open(auto, "w") as fh:
            fh.write(new_content)
        psql_sql("SELECT pg_reload_conf();", timeout=15)
        log("standby application_name refreshed to %s (applies on walreceiver reconnect)" % name)
    except Exception as exc:
        log("refresh standby application_name best-effort: %s" % exc)


def op_fixappname():
    record_appname(NODE_NAME)
    refresh_standby_appname(NODE_NAME)
    return STATUS_OK


def op_setappname(raw):
    name = (raw or "").strip().strip('"').strip() or NODE_NAME
    record_appname(name)
    refresh_standby_appname(name)
    return STATUS_OK


def op_setsync(raw):
    app = (raw or "").strip().strip('"').strip()
    if not app:
        return err("setsync: missing application_name")
    try:
        psql_sql(build_sync_sql(app), timeout=20)
        psql_sql("SELECT pg_reload_conf();", timeout=15)
        log("synchronous_standby_names -> FIRST 1 (%s)" % app)
        return STATUS_OK
    except Exception as exc:
        return err(exc)


def op_setasync(raw):
    try:
        psql_sql("ALTER SYSTEM RESET synchronous_standby_names;", timeout=20)
        psql_sql("SELECT pg_reload_conf();", timeout=15)
        log("synchronous_standby_names cleared (async)")
        return STATUS_OK
    except Exception as exc:
        return err(exc)


def op_updatepgpass(raw):
    try:
        entries = [ln.strip() for ln in (raw or "").replace("\r", "").split(",")]
        entries = [e for e in entries if e]
        if not entries:
            return err("updatepgpass: empty body")
        home = os.path.expanduser("~")
        pgpass = os.path.join(home, ".pgpass")
        existing = []
        try:
            with open(pgpass) as fh:
                existing = [ln.rstrip("\n") for ln in fh]
        except OSError:
            pass
        keys = set()
        merged = []
        for ln in existing + entries:
            key = ":".join(ln.split(":")[:4])
            if key in keys:
                continue
            keys.add(key)
            merged.append(ln)
        with open(pgpass, "w") as fh:
            fh.write("\n".join(merged) + "\n")
        os.chmod(pgpass, 0o600)
        return STATUS_OK + " (%d entries)" % len(merged)
    except Exception as exc:
        return err(exc)


def op_clear_autoconf():
    try:
        if pg_server_running() and pg_is_in_recovery():
            return STATUS_OK + " (standby; auto.conf untouched)"
        standby = os.path.join(PGDATA, "standby.signal")
        if os.path.exists(standby):
            os.remove(standby)
            log("clearAutoConf: removed stale standby.signal on primary")
        psql_sql("ALTER SYSTEM RESET primary_conninfo;", timeout=20)
        psql_sql("SELECT pg_reload_conf();", timeout=15)
        return STATUS_OK
    except Exception as exc:
        return err(exc)


def op_clean_backups():
    try:
        removed = 0
        for pattern in (
            "/var/lib/postgresql/*.backup",
            "/var/lib/postgresql/*.tar*",
            "/tmp/bfm-scratch-*",
        ):
            for path in glob.glob(pattern):
                try:
                    if os.path.isfile(path):
                        os.remove(path)
                        removed += 1
                except OSError:
                    pass
        # This image keeps no server-side backups (pg_basebackup streams
        # directly), so there is normally nothing to do.
        return STATUS_OK + " (%d stale files)" % removed
    except Exception as exc:
        return err(exc)


# --------------------------------------------------------------------------
# HTTP layer
# --------------------------------------------------------------------------

ROUTE_TABLE = {}
for _op in GET_OPS:
    ROUTE_TABLE[("GET", "/minipg/" + _op)] = _op
for _op in POST_OPS:
    ROUTE_TABLE[("POST", "/minipg/" + _op)] = _op
del _op


def dispatch(op, raw_body):
    data = parse_json_body(raw_body) if op in ("promote", "rewind", "rebaseUp", "post-so") else {}
    if op in ("pgstatus", "status"):
        return op_status() if op == "status" else op_pgstatus()
    if op == "checkpoint":
        return op_checkpoint()
    if op == "start":
        return op_start()
    if op == "stop":
        return op_stop()
    if op == "vip-up":
        return op_vip_up()
    if op == "vip-down":
        return op_vip_down()
    if op == "checkvip":
        return op_checkvip()
    if op == "pre-so":
        return op_pre_so()
    if op == "post-so":
        return op_post_so(data)
    if op == "fixappname":
        return op_fixappname()
    if op == "setappname":
        return op_setappname(raw_body)
    if op == "setsync":
        return op_setsync(raw_body)
    if op == "setasync":
        return op_setasync(raw_body)
    if op == "updatepgpass":
        return op_updatepgpass(raw_body)
    if op == "clearAutoConf":
        return op_clear_autoconf()
    if op == "cleanOldBackups":
        return op_clean_backups()
    if op == "promote":
        return op_promote(data)
    if op == "rewind":
        return op_rewind(data)
    if op == "rebaseUp":
        return op_rebaseup(data)
    return "ERROR: unknown op"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "bfm-minipg-agent/1.0"

    def log_message(self, fmt, *args):  # noqa: N802 (stdlib override)
        log("%s - %s" % (self.address_string(), fmt % args))

    def _send_text(self, code, body, extra_headers=None):
        payload = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _read_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        length = max(0, min(length, 65536))
        if length == 0:
            return ""
        try:
            return self.rfile.read(length).decode("utf-8", "replace")
        except (ConnectionResetError, ValueError):
            return ""

    def _authorized(self):
        # Re-read expected creds per request so a container env change
        # applies without an agent restart.
        exp_user = os.environ.get("MINIPG_USER", "bfm")
        exp_password = os.environ.get("MINIPG_PASSWORD", "bfm")
        if check_auth(self.headers.get("Authorization"), exp_user, exp_password):
            return True
        self._send_text(401, "unauthorized", unauthorized_headers())
        return False

    def _handle(self, method):
        path = self.path.split("?", 1)[0]
        if not path.startswith("/minipg/"):
            self._send_text(404, "not found")
            return
        if not self._authorized():
            return
        op = ROUTE_TABLE.get((method, path))
        if op is None:
            self._send_text(404, "ERROR: unknown op")
            return
        raw = self._read_body() if method == "POST" else ""
        try:
            body = dispatch(op, raw)
        except Exception as exc:  # never break BFM's loops
            body = err(exc)
        self._send_text(200, body)

    def do_GET(self):  # noqa: N802 (stdlib override)
        self._handle("GET")

    def do_POST(self):  # noqa: N802 (stdlib override)
        self._handle("POST")


def stop_pg_for_shutdown(timeout=25):
    try:
        if pg_server_running():
            log("SIGTERM: stopping PG (fast)")
            pg_ctl("-m", "fast", "-t", str(timeout), "-w", "stop", timeout=timeout + 10)
    except Exception as exc:
        log("SIGTERM stop best-effort: %s" % exc)


def serve():
    server = ThreadingHTTPServer(("0.0.0.0", MINIPG_PORT), Handler)

    def _on_term(signum, _frame):
        log("received signal %s; stopping PG and exiting" % signum)
        stop_pg_for_shutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, _on_term)
    signal.signal(signal.SIGINT, _on_term)
    log("listening on 0.0.0.0:%d as node %s (PGDATA=%s)" % (MINIPG_PORT, NODE_NAME, PGDATA))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


# --------------------------------------------------------------------------
# Offline self-check: route table + auth-challenge + translation + parsing.
# No PG, sockets, or docker needed: `python3 minipg-agent.py --self-check`.
# --------------------------------------------------------------------------

def self_check():
    failures = []

    def check(name, cond):
        print(("PASS: %s" % name) if cond else ("FAIL: %s" % name), flush=True)
        if not cond:
            failures.append(name)

    # 1. Route table covers every op BFM calls, with the right methods.
    expected_get = {("GET", "/minipg/" + op) for op in GET_OPS}
    expected_post = {("POST", "/minipg/" + op) for op in POST_OPS}
    check("route-table/get-count", len([k for k in ROUTE_TABLE if k[0] == "GET"]) == 12)
    check("route-table/post-count", len([k for k in ROUTE_TABLE if k[0] == "POST"]) == 8)
    check("route-table/get-exact", expected_get <= set(ROUTE_TABLE))
    check("route-table/post-exact", expected_post <= set(ROUTE_TABLE))
    check("route-table/total", len(ROUTE_TABLE) == 20)
    check(
        "route-table/method-isolation",
        ("POST", "/minipg/status") not in ROUTE_TABLE
        and ("GET", "/minipg/promote") not in ROUTE_TABLE
        and ("GET", "/minipg/setsync") not in ROUTE_TABLE,
    )

    # 2. Auth: preemptive Basic accepted; missing/invalid -> challenge.
    def basic(user, password):
        blob = base64.b64encode(("%s:%s" % (user, password)).encode()).decode()
        return "Basic %s" % blob

    check("auth/preemptive-valid", check_auth(basic("bfm", "bfm"), "bfm", "bfm"))
    check("auth/missing", not check_auth(None, "bfm", "bfm"))
    check("auth/empty", not check_auth("", "bfm", "bfm"))
    check("auth/wrong-password", not check_auth(basic("bfm", "nope"), "bfm", "bfm"))
    check("auth/wrong-user", not check_auth(basic("nope", "bfm"), "bfm", "bfm"))
    check("auth/wrong-scheme", not check_auth("Bearer abc", "bfm", "bfm"))
    check("auth/malformed-b64", not check_auth("Basic !!!", "bfm", "bfm"))
    check("auth/no-colon", not check_auth("Basic %s" % base64.b64encode(b"nocolon").decode(), "bfm", "bfm"))
    check(
        "auth/custom-creds",
        check_auth(basic("minipg", "s3cret"), "minipg", "s3cret")
        and not check_auth(basic("bfm", "bfm"), "minipg", "s3cret"),
    )
    headers = unauthorized_headers()
    check(
        "auth/challenge-header",
        headers.get("WWW-Authenticate", "").startswith("Basic"),
    )

    # 3. Host-mapped endpoint translation (BFM host view -> container view).
    check(
        "translate/pg1",
        translate_endpoint("127.0.10.11", "5432") == ("live-pg1", "5432"),
    )
    check(
        "translate/pg2-published-port",
        translate_endpoint("127.0.10.12", "5433") == ("live-pg2", "5432"),
    )
    check(
        "translate/hostname-passthrough",
        translate_endpoint("live-pg1", "5432") == ("live-pg1", "5432"),
    )
    check(
        "translate/other-passthrough",
        translate_endpoint("10.0.0.5", "5433") == ("10.0.0.5", "5433"),
    )
    check(
        "translate/blank-port-defaults",
        translate_endpoint("live-pg2", "") == ("live-pg2", "5432"),
    )

    # 4. Body parsing for the JSON POST ops (field names per BFM DTOs).
    rewind_data = parse_json_body(
        '{"masterIp": "127.0.10.12", "port": "5433", "user": "bfm", '
        '"password": "bfm", "tablespaceList": []}'
    )
    check("parse/rewind-json", master_from_rewind(rewind_data)["host"] == "live-pg2")
    check("parse/rewind-port", master_from_rewind(rewind_data)["port"] == "5432")
    check("parse/rewind-user", master_from_rewind(rewind_data)["user"] == "bfm")
    rebase_data = parse_json_body(
        '{"masterIp": "127.0.10.11", "masterPort": "5432", "repUser": "bfm", '
        '"repPassword": "bfm", "tablespaceList": null}'
    )
    check("parse/rebase-host", master_from_rebase(rebase_data) == {
        "host": "live-pg1",
        "port": "5432",
        "user": "bfm",
        "password": "bfm",
    })
    check("parse/garbage-body", parse_json_body("not json") == {})
    check("parse/empty-body", parse_json_body("") == {})

    # 5. Response contract literals BFM gates on.
    check("contract/status-ok", STATUS_OK == "OK")
    check("contract/start-body", "done" in START_OK and "server started" in START_OK)
    check(
        "contract/sync-quoting",
        build_sync_sql('a"b') == 'ALTER SYSTEM SET synchronous_standby_names = \'FIRST 1 ("a""b")\';',
    )

    # 6. Promote verdict (pure helper, no PG): OK only when actually primary.
    check("promote/primary-ok", promote_verdict(0, "promoted", "", False) == "OK")
    already = promote_verdict(1, "already primary", "failed: already primary", False)
    check(
        "promote/already-primary-ok",
        already.startswith("OK") and "already primary" in already,
    )
    still = promote_verdict(1, "ctl-boom", "pg-promote-boom", True)
    check(
        "promote/still-standby-error",
        not still.startswith("OK")
        and "ctl-boom" in still
        and "pg-promote-boom" in still,
    )
    down = promote_verdict(1, "ctl-down", "pg-down", None, "connection refused")
    check(
        "promote/unreachable-error",
        not down.startswith("OK")
        and "ctl-down" in down
        and "pg-down" in down,
    )

    print(
        "self-check: %s" % ("ALL PASS" if not failures else "%d FAILURES: %s" % (len(failures), failures)),
        flush=True,
    )
    return 1 if failures else 0


if __name__ == "__main__":
    if "--self-check" in sys.argv[1:]:
        sys.exit(self_check())
    serve()
