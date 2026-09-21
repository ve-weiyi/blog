#!/bin/bash
# 把本目录下的配置发布到集群内的 Nacos。
#
# 用法（在仓库根目录执行）：
#   bash deploy/nacos-config/publish.sh              # 发布 test 与 prod 全部
#   bash deploy/nacos-config/publish.sh prod         # 只发布 prod
#   bash deploy/nacos-config/publish.sh prod app-api # 只发布 prod 的 app-api
#
# 认证方式：走 Nacos 的 server-identity 头（NACOS_AUTH_IDENTITY_KEY / _VALUE），
# 而不是用户登录。原因见 README「关于认证」。
#
# 目录约定：<env>/<dataId>.yaml —— 文件名即 Nacos 的 dataId。

set -euo pipefail

NAMESPACE="blog"
NACOS_SVC="nacos"
NACOS_PORT="8848"
NACOS_GROUP="veweiyi.cn"
SEED_CM="nacos-seed"
SEED_POD="nacos-publish"

# 与 deploy/k8s/env.yaml 中的 NACOS_AUTH_IDENTITY_KEY / _VALUE 一致
IDENTITY_KEY="serverIdentity"
IDENTITY_VALUE="security"

CONFIG_DIR="$(cd "$(dirname "$0")" && pwd)"
KUBECTL="kubectl"
[ -n "${KUBECONFIG_FILE:-}" ] && KUBECTL="kubectl --kubeconfig=${KUBECONFIG_FILE}"

if [ $# -eq 0 ]; then
  ENVS=(test prod); SERVICES=(blog-rpc app-api admin-api)
elif [ $# -eq 1 ]; then
  ENVS=("$1");     SERVICES=(blog-rpc app-api admin-api)
else
  ENVS=("$1");     SERVICES=("$2")
fi

cleanup() {
  $KUBECTL -n "$NAMESPACE" delete pod "$SEED_POD" --ignore-not-found >/dev/null 2>&1 || true
  $KUBECTL -n "$NAMESPACE" delete configmap "$SEED_CM" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo ">>> 载入配置到临时 ConfigMap"
from_file=()
for env in "${ENVS[@]}"; do
  for svc in "${SERVICES[@]}"; do
    f="$CONFIG_DIR/$env/$svc.yaml"
    [ -f "$f" ] || { echo "缺少文件: $f" >&2; exit 1; }
    from_file+=("--from-file=${env}__${svc}.yaml=$f")
  done
done
cleanup
$KUBECTL -n "$NAMESPACE" create configmap "$SEED_CM" "${from_file[@]}" --dry-run=client -o yaml \
  | $KUBECTL apply -f - >/dev/null

echo ">>> 起 Pod 发布"
$KUBECTL apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${SEED_POD}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: pub
      image: curlimages/curl
      volumeMounts:
        - {name: seed, mountPath: /seed}
      command: ["sh","-c"]
      args:
        - |
          set -e
          for f in /seed/*; do
            b=\$(basename "\$f"); env=\${b%%__*}; svc=\${b##*__}; svc=\${svc%.yaml}
            printf "  %-6s %-10s -> " "\$env" "\$svc"
            curl -sf -m 15 -X POST "http://${NACOS_SVC}:${NACOS_PORT}/nacos/v3/admin/cs/config" \\
              -H "${IDENTITY_KEY}: ${IDENTITY_VALUE}" \\
              --data-urlencode "dataId=\$svc" \\
              --data-urlencode "groupName=${NACOS_GROUP}" \\
              --data-urlencode "namespaceId=\$env" \\
              --data-urlencode "type=yaml" \\
              --data-urlencode "content@\$f" | head -c 60
            echo
          done
  volumes:
    - name: seed
      configMap: {name: ${SEED_CM}}
EOF

for _ in $(seq 1 30); do
  ph=$($KUBECTL -n "$NAMESPACE" get pod "$SEED_POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [ "$ph" = "Succeeded" ] || [ "$ph" = "Failed" ] && break
  sleep 2
done
$KUBECTL -n "$NAMESPACE" logs "$SEED_POD"
[ "$ph" = "Succeeded" ] && echo ">>> 发布完成" || { echo ">>> 发布失败" >&2; exit 1; }
