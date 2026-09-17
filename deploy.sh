#!/bin/sh
# Deploy or update the monitoring agent on a remote host:
#
#   ./deploy.sh <user@host> [bind_ip]
#
# Copies docker-compose.yml to ~/monitoring_agent on the target, seeds
# BIND_IP in ~/monitoring_agent/.env if it is not set there yet (default:
# the host part of <user@host>, i.e. the address Prometheus scrapes) and runs
# `docker compose up -d` (a no-op if nothing changed). Existing .env lines are
# left alone, so per-host overrides (see .env.example) survive redeploys.
# The per-host identity (host label) lives on the server side: register new
# hosts once in MONITOR_HOSTS in /home/runner/monitoring/.env on hydra.
set -eu

TARGET=${1:?usage: ./deploy.sh <user@host> [bind_ip]}
BIND_IP=${2:-${TARGET#*@}}
SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

ssh "$TARGET" 'mkdir -p ~/monitoring_agent'
scp -q "$SRC/docker-compose.yml" "$TARGET:monitoring_agent/docker-compose.yml"
ssh "$TARGET" "cd ~/monitoring_agent && { grep -q '^BIND_IP=' .env 2>/dev/null || echo 'BIND_IP=$BIND_IP' >> .env; }"
ssh "$TARGET" 'cd ~/monitoring_agent && docker compose pull -q && docker compose up -d'
ssh "$TARGET" 'cd ~/monitoring_agent && docker compose ps'

echo
echo "Agent deployed on $TARGET."
echo "New host? Register it once on hydra: add '<name>:<ip>' to MONITOR_HOSTS in"
echo "/home/runner/monitoring/.env, then 'docker compose up -d prometheus' and run"
echo "the verify gate (see monitoring/CLAUDE.md)."
