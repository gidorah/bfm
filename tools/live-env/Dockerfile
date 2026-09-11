# bfm-live PG+MiniPG node image (issue #18, part B).
#
# One service per node (live-pg1/live-pg2); each container runs one
# PostgreSQL plus its compatible MiniPG agent (tools/live-env/minipg-agent.py,
# stdlib-only python3). Build context is the repo root (compose.yaml sets
# `context: ../..`, which resolves to the repo root both from
# tools/live-env/compose.yaml and from the helper-staged copy at
# _work-tmp/live-env/compose.yaml).
FROM postgres:16-bookworm

# python3 for the agent; single layer, no recommends, apt lists dropped.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/*

COPY tools/live-env/minipg-agent.py /opt/bfm/minipg-agent.py
COPY --chmod=755 tools/live-env/docker/entrypoint.sh /opt/bfm/docker/entrypoint.sh
COPY tools/live-env/docker/pg_hba.live.conf /opt/bfm/docker/pg_hba.live.conf

# PG listens on 5432 and the agent on 7779 inside the container (host
# publishes differ per node; see compose.yaml).
EXPOSE 5432 7779

ENTRYPOINT ["/opt/bfm/docker/entrypoint.sh"]
