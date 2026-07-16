#!/bin/sh
# Deploy or update the monitoring agent on a remote host:
#
#   ./deploy.sh <user@host>
#
# Copies docker-compose.yml to ~/monitoring_agent on the target and runs
# `docker compose up -d` there (a no-op if nothing changed). The agent itself
# is identical on every host — the per-host identity (host label) lives on
# the server side: register new hosts once in MONITOR_HOSTS in
# /home/runner/monitoring/.env on hydra.
set -eu

TARGET=${1:?usage: ./deploy.sh <user@host>}
SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

ssh "$TARGET" 'mkdir -p ~/monitoring_agent'
scp -q "$SRC/docker-compose.yml" "$TARGET:monitoring_agent/docker-compose.yml"
ssh "$TARGET" 'cd ~/monitoring_agent && docker compose pull -q && docker compose up -d'
ssh "$TARGET" 'cd ~/monitoring_agent && docker compose ps'

echo
echo "Agent deployed on $TARGET."
echo "New host? Register it once on hydra: add '<name>:<ip>' to MONITOR_HOSTS in"
echo "/home/runner/monitoring/.env, then 'docker compose up -d prometheus' and run"
echo "the verify gate (see monitoring/CLAUDE.md)."
