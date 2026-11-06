# E2E 契约测试骨架

对运行中的真实链路做**少量关键路径**的契约验证，不替代单元测试与集成测试。
定位对应 `docs/design/51-测试与质量门禁.md` 的「端到端」层。

## 边界

- 只跑 `cases/` 里显式列出的套件，默认 `smoke`；
- 用例只绑定 **operation**（`.api` 里的 `@handler` 名），不写死路径；
- 每个 operation 必须先在 `spec/safety.json` 里被规则覆盖，未覆盖一律视为 `unimplemented` 并拒绝执行；
- `destructive` 永远拒绝，`heavy` 需要 `--allow-heavy` 显式放行；
- 骨架阶段只跑只读用例；接入写用例后，测试数据使用 `e2e-<run_id>-` 前缀并按逆序清理。

## 用法

```bash
# 从 protocol/api 重新生成端点清单（契约变更后执行）
python3 test/e2e/run.py --generate

# 对本地网关跑 smoke
E2E_BASE_URL=http://127.0.0.1:9420 python3 test/e2e/run.py --suite smoke

# 需要登录态的用例：账号密码缺失时自动跳过，不会失败
E2E_BASE_URL=http://127.0.0.1:9420 \
E2E_ACCOUNT=you@example.com E2E_PASSWORD=... \
python3 test/e2e/run.py --suite smoke

# 写套件：先取一篇文章，再点赞/取消点赞（自带还原，不留下数据）
# like/unlike 属于 heavy，必须显式放行
E2E_BASE_URL=http://127.0.0.1:9420 \
E2E_ACCOUNT=you@example.com E2E_PASSWORD=... \
python3 test/e2e/run.py --suite write --allow-heavy
```

环境变量：

| 变量 | 必填 | 说明 |
|---|---|---|
| `E2E_BASE_URL` | 是 | 网关根地址，不带路径 |
| `E2E_ACCOUNT` / `E2E_PASSWORD` | 否 | 缺省时 `auth: true` 的用例标记为 skip |
| `E2E_TIMEOUT` | 否 | 单请求超时秒数，默认 10 |

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 全部通过（skip 不算失败） |
| 1 | 断言失败 |
| 2 | 环境错误（连不上网关、登录失败等） |
| 3 | 契约/安全清单漂移（端点缺失、未分级、用例引用了不存在的 operation） |

## 目录

```
test/e2e/
├── cases/          用例套件（JSON）
├── engine/         解析、安全分级、HTTP 客户端与执行器
├── spec/           endpoints.json（生成）与 safety.json（人工维护）
├── tests/          骨架自身的单元测试，不联网
└── run.py          CLI
```

## 自测

```bash
python3 -m unittest discover -s test/e2e/tests -v
```

`endpoints.json` 由 `.api` 生成，随契约变更一起提交；`--check` 可在 CI 里检测漂移。
