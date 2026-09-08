# 后端约定

## 分层与目录结构

后端分层（api：`handler → logic → svc / core`；rpc：`handler → logic → svc / core`）与目录结构见 [`architecture.md`](architecture.md)（唯一真相源）。

### 各层职责

**handler 层** — 路由注册 / gRPC 方法实现 + 参数校验 + 调用 logic + 响应封装；**禁止**承载任何业务逻辑。目录 `internal/handler/<module>/`。

**logic 层** — 业务编排。api 经 gRPC client 调用下游服务，**禁止**使用 HTTP 相关类型（HTTP 语义不侵入业务层）；rpc 实现核心业务逻辑。目录 `internal/logic/<module>/<method>_logic.go`。

**core 层** — 核心引擎，供 logic 调用：

**svc 层** — 依赖注入容器：配置、gRPC client、DB 连接等。目录 `internal/svc/`。

## 统一响应格式

```json
{
    "code": "<int>",
    "msg":  "<string>",
    "data": "<object>"
}
```

- 成功：`code = 200`
- 错误：`code` 为具体错误码，`msg` 为错误描述

## API 修改流程

**不可跳步，必须按顺序执行：**

```
1. 修改 protocol/api/<service>.api（HTTP 网关）或 protocol/proto/<service>.proto（gRPC）
2. 运行对应 generate.sh 重新生成代码
3. 修改 types 定义（如有自定义类型）
4. 修改 logic 层实现业务逻辑
```

- 禁止跳过步骤 1 直接修改生成文件
- 禁止跳过步骤 2 直接修改 logic 层

### generate.sh 位置

| 场景 | 脚本路径 |
|------|---------|
| gRPC proto | `protocol/proto/generate.sh` |
| HTTP API | `protocol/api/generate.sh` |

## 数据库操作规则

### 禁止 N+1 查询

**禁止**在 for 循环中调用数据库查询方法（循环小于3则可以保留）：

```go
// ❌ 错误：N+1
for _, item := range items {
    record, _ := model.FindOne(ctx, "id = ?", item.ID)
}

// ✅ 正确：批量 IN 查询 + map
ids := make([]int64, 0, len(items))
for _, item := range items {
    ids = append(ids, item.ID)
}
records, _ := model.FindALL(ctx, "id IN ?", ids)
recordMap := make(map[int64]*Model, len(records))
for _, r := range records {
    recordMap[r.Id] = r
}
for _, item := range items {
    record := recordMap[item.ID]  // O(1) 查找
}
```

### GORM 规范

- `IN` 子句：直接传切片，GORM 自动展开
- 批量查询命名：`FindALL`
- 单个查询命名：`FindOne`
- 禁止字符串拼接 SQL，使用参数化查询

## 错误处理

- 必须显式检查 error，不可忽略
- 错误信息要包含足够的上下文便于排查
- panic 仅用于不可恢复的程序错误
