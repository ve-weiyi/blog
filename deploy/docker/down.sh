#!/usr/bin/env bash
#
# Docker 单机形态的停止入口，与 up.sh 对称。
#
#   bash deploy/docker/down.sh          # 应用与依赖都停
#   bash deploy/docker/down.sh deps     # 只停依赖
#   bash deploy/docker/down.sh app      # 只停应用
#
# 只停容器，**不删卷** —— 数据保留。要清数据得显式 docker compose ... down -v。
# blog-net 是 external 网络，down 不会删除它。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPS="$ROOT/deploy/docker-compose"
APP="$ROOT/deploy/docker"

stop_app() {
  echo "停止应用 ..."
  docker compose -f "$APP/docker-compose.yml" down
}

stop_deps() {
  # 与 up.sh 相反的顺序
  for s in minio/minio nacos/nacos etcd/etcd rabbitmq/rabbitmq redis/redis mysql/mysql; do
    echo "停止 $s ..."
    docker compose -f "$DEPS/$s.yaml" down
  done
}

case "${1:-all}" in
  deps) stop_deps ;;
  app)  stop_app ;;
  all)  stop_app; stop_deps ;;
  *)    echo "用法: $0 [deps|app]" >&2; exit 2 ;;
esac

echo "完成。"
