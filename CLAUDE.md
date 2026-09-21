两个参考项目路径：

/Users/weiyi/GolandProjects/yocto/kumo 

/Users/weiyi/GolandProjects/yocto/scan

# 项目上下文

## 部署

| 想要什么 | 看哪 |
|---|---|
| 部署步骤、服务清单 | [`deploy/k8s/k8s集群部署指南.md`](deploy/k8s/k8s集群部署指南.md)（**唯一真相源**） |
| **出问题了怎么查、已知故障模式** | [`.claude/rules/k8s-ops.md`](.claude/rules/k8s-ops.md) |
| 选哪种部署形态（k8s / docker / 源码构建） | [`deploy/README.md`](deploy/README.md) |
| Nacos 配置（test / prod 两环境） | [`deploy/nacos-config/配置说明.md`](deploy/nacos-config/配置说明.md) |

集群现状一条命令自查（**不要凭记忆断言状态**）：

```bash
kubectl --kubeconfig=deploy/k8s/k8s-config.yaml get pod,pvc,certificate -n blog
```

### 两套 k3s 集群，勿混用

| | 腾讯云 | 本地 |
|---|---|---|
| 地址 | `159.75.154.50:6443`（内网 `10.1.20.12`） | `172.18.116.85` |
| 节点 / 版本 | `k3s-master` / v1.36.4+k3s1 | `dell3080` / v1.35.5 |
| kubeconfig | `deploy/k8s/k8s-config.yaml`（gitignored） | `~/.kube/config` |

两者集群内容完全不同（本地跑 kumo / ragflow / seafile），把一边的状态当成另一边的会得出错误结论。`k8s-config.yaml` 必须带 `tls-server-name: k3s-master` —— API server 证书的 SAN 不含公网 IP，直连会报 x509 校验失败。

### 操作注意

- **KUBECONFIG 不跨 Bash 调用保持，且本项目有两套集群** —— 漏指定会静默回落到 `~/.kube/config`（另一套集群）或 `localhost:8080`，查出错误结果且不报错。**每条 kubectl 都显式带 `--kubeconfig`**，不要依赖环境变量：
  ```bash
  kubectl --kubeconfig=deploy/k8s/k8s-config.yaml get pod -n blog
  ```
- 存储供给器无需部署 —— k3s 自带 local-path provisioner，`StorageClass/local-path` 随集群创建即存在。别从上游引入 local-path 清单：`StorageClass/local-path`、`ClusterRole/local-path-provisioner-role`、`ClusterRoleBinding/local-path-provisioner-bind` 会与内置对象同名冲突。
- 全部清单显式声明 `namespace: blog` —— 中间件与应用同命名空间，应用经服务短名（`mysql` / `redis` / `rabbitmq` / `minio` / `etcd` / `nacos`）直接访问。
- 凭据方案已收敛：所有中间件与应用均引用 `deploy/k8s/env.yaml` 的 Secret `blog-env`，不再有内联的 `*-secret`。

### 凭据

**不准写进文档、注释、提交信息**。`k8s-config.yaml`（含 `system:masters` 私钥）已 gitignore；读取时用脚本处理，避免私钥进入对话上下文。

`deploy/k8s/env.yaml` 含明文密码且**未** gitignore，已随 `4191885` 进入本地历史。`main` 尚未 push 到 origin，推送前是最后可挽回的窗口（`git rm --cached` + 改写历史）；推上去就只能改密码。

**同一批密码散落在四处，手工保持一致，无自动同步** —— 改任何一处都要同步其余：

| 位置 | 内容 |
|---|---|
| `deploy/k8s/env.yaml` | Secret `blog-env`，k8s 侧唯一凭据源 |
| `deploy/nacos-config/{test,prod}/*.yaml` | 应用运行配置里的数据源口令（**已入库**） |
| `deploy/docker/.env` | Docker 形态的 Nacos 连接参数 |
| `deploy/docker-compose/*/` | 各中间件 compose 的内联环境变量 |

应用侧另有一处：Nacos 控制台的 `NACOS_USERNAME/PASSWORD` 写在 `deploy/k8s/app/nacos-config.yaml` 这个 **ConfigMap** 里（不是 Secret），技术上该挪走。

### 远程写入的权限

`root@159.75.154.50` 已配 SSH 免密。但 Claude Code 的 auto mode 语义分类器会拦截「写远程系统配置 / 重启服务」这类操作 —— **表达授权意愿不够，需要在确认框中点名具体操作**（改哪个文件、重启哪个服务）。
