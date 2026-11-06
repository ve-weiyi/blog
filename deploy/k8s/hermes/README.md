# Hermes Agent（AI 助手）

单实例共享部署：一个 Deployment + PVC + ClusterIP Service，供 blog-cloud 调用。
清单是 `hermes.yaml`，**默认不 apply**，部署由人工择机执行。

## 前置：创建 Secret

密钥不进仓库。`API_SERVER_KEY` 自己生成（同时供 Hermes 入站和 app-api 调用使用）；
`DEEPSEEK_API_KEY` 用真实模型密钥，只给 Hermes 调模型：

```bash
kubectl --kubeconfig=deploy/k8s/k8s-config.yaml -n blog create secret generic hermes-secret \
  --from-literal=API_SERVER_KEY="$(openssl rand -hex 32)" \
  --from-literal=DEEPSEEK_API_KEY="<真实密钥>"
```

已有 Secret 时用 `kubectl -n blog patch secret hermes-secret --type merge -p '{"stringData":{...}}'`。

app-api 的 `AI_API_KEY` 就是从 `hermes-secret/API_SERVER_KEY` 注入的，不需要在 `blog-env` 里重复保存。
App-api 的 Nacos 配置里 `AiConf.base_url` 指向 `http://hermes:8080/v1`（test 环境走端口转发
`http://127.0.0.1:18642/v1`）。

## 部署

```bash
kubectl --kubeconfig=deploy/k8s/k8s-config.yaml apply -f deploy/k8s/hermes/hermes.yaml
kubectl --kubeconfig=deploy/k8s/k8s-config.yaml -n blog rollout status deployment/hermes --timeout=180s
```

镜像 `nousresearch/hermes-agent:v2026.7.7.2` 来自 Docker Hub（约 1.1 GB）。腾讯云节点拉取失败时，
需要给 k3s 配镜像加速，或先把镜像同步到可访问的仓库再改 `image:`。

## 验证

```bash
# 端口转发后检查健康与模型列表
kubectl --kubeconfig=deploy/k8s/k8s-config.yaml -n blog port-forward svc/hermes 18642:8080

curl -s -H "Authorization: Bearer $API_SERVER_KEY" http://127.0.0.1:18642/health
curl -s -H "Authorization: Bearer $API_SERVER_KEY" http://127.0.0.1:18642/v1/models
```

真实对话冒烟（会话 API）：

```bash
curl -sN -H "Authorization: Bearer $API_SERVER_KEY" -H 'Content-Type: application/json' \
  -X POST http://127.0.0.1:18642/api/sessions \
  -d '{"title":"smoke"}'

curl -sN -H "Authorization: Bearer $API_SERVER_KEY" -H 'Content-Type: application/json' \
  -X POST http://127.0.0.1:18642/api/sessions/<session_id>/chat/stream \
  -d '{"message":"用一句话介绍你自己"}'
```

## 实测（2026-11-05，腾讯云节点）

- Pod `1/1 Running`，内存约 `224Mi`（limits 1Gi），节点整体内存约 84%
- `GET /health` 返回 `0.18.2`；`GET /v1/models` 返回 `hermes-agent`
- 流式对话正常；用本项目 `cmd/ai-check` 指向 Hermes 的 `/v1` 也能跑通
- 一次问答的 `prompt_tokens` 约 15.9k（Hermes 自带系统提示与工具描述），成本与延迟明显高于直连模型，配额需要按此口径评估
- 要求执行 `echo` 的测试被拒绝（人设与 AGENTS.md 生效），但日志仍提示 API Server 以未沙箱的 local 终端运行，属于残余风险

## 资源与安全

- **内存**：节点实际内存已用约 82%。这里 requests 256Mi、limits 1Gi 属于限额试跑；出现
  `OOMKilled` 或节点其他服务异常时，先扩节点内存，不要直接去掉 limit。
- **RWO PVC + 单副本**：必须 `Recreate`，滚动更新会卡在 Pending。
- **工具面**：Hermes 自带终端/文件/网络等内置工具。当前配置 `approvals.mode: smart` 且
  `command_allowlist: []`，并用人设与 AGENTS.md 明确禁止执行命令；**接入公网访客前必须复核这一点**，
  最稳妥的是只允许只读工具或在 NetworkPolicy 层限制出站。
- **密钥**：只从 Secret 注入；不要写进 `config.yaml`、ConfigMap 或镜像。
- **会话数据**：存在 `hermes-data` PVC（`local-path`，回收策略 Delete），节点/PVC 丢失即会话丢失，
  与 kumo 的已知风险相同。

## 升级与回滚

```bash
# 升级：改 image tag 后重新 apply（Recreate，会有短暂中断）
kubectl --kubeconfig=deploy/k8s/k8s-config.yaml apply -f deploy/k8s/hermes/hermes.yaml
kubectl --kubeconfig=deploy/k8s/k8s-config.yaml -n blog rollout status deployment/hermes

# 回滚：改回上一个 tag 再 apply；或 kubectl -n blog rollout undo deployment/hermes
```

## 接入状态

已按**无状态 OpenAI 兼容端点**接入（设计 D11）：

- Nacos 的 `AiConf.base_url` 指向 `http://hermes:8080/v1`（test 走端口转发）
- 会话、消息、检索、预算与配额仍由 blog-cloud 保管，不调用 Hermes 的 `/api/sessions`
- 原因：共享实例的会话存在同一个 PVC 上，且 Agent 工具可读该存储，无法隔离不同用户

未使用 Hermes 的会话 API；如果以后需要跨轮记忆/工具事件，应先解决每用户隔离（独立 Pod 或等价方案）。
