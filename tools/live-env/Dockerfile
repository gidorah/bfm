# bfm-live PG+MiniPG node image (issue #23, part A).
#
# One service per node (live-pg1/live-pg2); each container runs one
# PostgreSQL 14 plus its REAL minipg4patroni sidecar jar
# (sibling checkout ../minipgonpatroni, app/target/minipg4patroni-app-*.jar).
# Build context is the repo root (compose.yaml sets `context: ../..`, which
# resolves to the repo root both from tools/live-env/compose.yaml and from
# the helper-staged copy at _work-tmp/live-env/compose.yaml).
#
# Jar staging (Worker B owns tools/live-env/live-env.sh `prepare`): prepare
# builds the jar from the sibling checkout
#   ./mvnw -f ../minipgonpatroni/pom.xml -pl app -am package
# or honors $BFM_LIVE_MINIPG_JAR when set, then copies the chosen jar to
# _work-tmp/live-env/minipg.jar (in-context staged path COPYed below).
# To build manually without the helper:
#   cp <minipg4patroni-app-*.jar> _work-tmp/live-env/minipg.jar
# then `docker compose -f tools/live-env/compose.yaml build`.
#
# configuration.json choice (documented per ticket): a SINGLE static
# tools/live-env/configuration.json is COPYed into the image as the default —
# NO per-node substitution is needed because every value is node-identical
# (shared VIP 172.30.51.100, identical PG paths, fixed test-only bfm/bfm
# creds, same port 7779). At runtime compose bind-mounts the prepare-staged
# per-node file (_work-tmp/live-env/pg1|pg2/configuration.json, verbatim from
# this template) over /opt/bfm/configuration.json, so prepare-time values win
# without a rebuild. Both services share the same content. vipIpNetmask is "24" (CIDR prefix
# length): `ip address add <vip>/<mask>` requires a numeric prefix, so the
# dotted form (255.255.255.0) would fail vip-up; the reference env's dotted
# value was never exercised on that path.
#
# Pinned topology (fixed contract, Worker B parity):
#   bridge 172.30.51.0/24, live-pg1 172.30.51.11, live-pg2 172.30.51.12,
#   VIP 172.30.51.100, PG 5432 + minipg 7779 on both nodes (distinct IPs,
#   same ports), BFM 127.0.0.1:9995. No ports: published.
FROM eclipse-temurin:21-jre-jammy AS java

FROM postgres:14.13-bookworm

# JRE 21 for the sidecar jar (same copy pattern as the reference
# member.Dockerfile); PG14 bin dir first on PATH so psql/pg_ctl/
# pg_basebackup/pg_rewind resolve for the jar and healthchecks.
COPY --from=java /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="/opt/java/openjdk/bin:/usr/lib/postgresql/14/bin:${PATH}"

# iproute2 for the jar's `ip address add/del` VIP ops + sudo for the
# passwordless grants below. Single layer, no recommends, apt lists dropped.
RUN apt-get update \
  && apt-get install -y --no-install-recommends iproute2 sudo curl \
  && rm -rf /var/lib/apt/lists/* \
  && printf '%s\n' \
    'postgres ALL=(ALL) NOPASSWD: /sbin/ip address add *, /sbin/ip address del *' \
    'postgres ALL=(ALL) NOPASSWD: /usr/sbin/ip address add *, /usr/sbin/ip address del *' \
    'postgres ALL=(ALL) NOPASSWD: /bin/true' \
    > /etc/sudoers.d/bfm-minipg \
  && chmod 0440 /etc/sudoers.d/bfm-minipg \
  && visudo -c

# Staged by prepare (see header); fixed test-only jar, never production.
COPY _work-tmp/live-env/minipg.jar /opt/bfm/minipg.jar
# Single static per-node config (node-identical; see header choice note).
COPY tools/live-env/configuration.json /opt/bfm/configuration.json
COPY --chmod=755 tools/live-env/docker/entrypoint.sh /opt/bfm/docker/entrypoint.sh
COPY tools/live-env/docker/pg_hba.live.conf /opt/bfm/docker/pg_hba.live.conf

RUN chown -R postgres:postgres /opt/bfm \
  && chmod 644 /opt/bfm/configuration.json /opt/bfm/docker/pg_hba.live.conf

# Jar CWD: ConfigurationManager reads CWD-relative ./configuration.json,
# so the jar must run with CWD=/opt/bfm (entrypoint cds there as well).
WORKDIR /opt/bfm

# PG listens on 5432 and the jar on 7779 inside the container (no published
# ports: the host reaches container IPs on the pinned bridge directly).
EXPOSE 5432 7779

ENTRYPOINT ["/opt/bfm/docker/entrypoint.sh"]
