# goctlx 升级后 antlr 与 ddl-parser 不兼容

- **日期**：2026-10-22
- **模块**：`goctlx`
- **状态**：已修复（2026-10-22，钉版后 `build` / `vet` / `test -short` 通过）
- **触发操作**：`GOPROXY=https://goproxy.cn GOWORK=off go get -u ./...`

## 一、现象

`go get -u ./...` 把 `antlr` 从旧伪版本升到 `v1.4.10`：

```
go: upgraded github.com/antlr/antlr4/runtime/Go/antlr v0.0.0-20210521184019-c5ad59b459ec => v1.4.10
```

随后 `go build ./...` 与 `go vet ./...` 失败：

```
# github.com/zeromicro/ddl-parser/gen
../../../go/pkg/mod/github.com/zeromicro/ddl-parser@v1.0.5/gen/mysql_lexer.go:6585:32:
  lexerDeserializer.DeserializeFromUInt16 undefined
  (type *antlr.ATNDeserializer has no field or method DeserializeFromUInt16)
../../../go/pkg/mod/github.com/zeromicro/ddl-parser@v1.0.5/gen/mysql_parser.go:4071:34:
  deserializer.DeserializeFromUInt16 undefined
  (type *antlr.ATNDeserializer has no field or method DeserializeFromUInt16)
```

## 二、根因

`github.com/zeromicro/ddl-parser v1.0.5` 的生成代码依赖旧版 ANTLR Go runtime 的 `DeserializeFromUInt16`：

```
github.com/zeromicro/ddl-parser v1.0.5
  require github.com/antlr/antlr4/runtime/Go/antlr v0.0.0-20210521184019-c5ad59b459ec
```

`goctl v1.10.2` 同样要求旧伪版本：

```
github.com/zeromicro/go-zero/tools/goctl v1.10.2
  require github.com/antlr/antlr4/runtime/Go/antlr v0.0.0-20210521184019-c5ad59b459ec
```

`antlr v1.4.10` 移除了该方法，属于上游 API 破坏性变更。`go get -u ./...` 按「同 major 内取最新」把它升到 `v1.4.10`，MVS 选择最高版本后，`ddl-parser` 的生成代码无法编译。

## 三、修复

把 `antlr` 钉回 `ddl-parser` 与 `goctl` 共同要求的伪版本，其余依赖更新保留：

```bash
cd goctlx
GOPROXY=https://goproxy.cn GOWORK=off go get \
  github.com/antlr/antlr4/runtime/Go/antlr@v0.0.0-20210521184019-c5ad59b459ec
GOWORK=off go mod tidy
GOWORK=off go build ./...
GOWORK=off go vet ./...
```

验证依赖图：

```bash
GOWORK=off go mod graph | grep antlr
```

应看到 `ddl-parser` 与 `goctl` 都指向伪版本，而不是 `v1.4.10`。

## 四、预防

- `goctlx` 的 `go get -u ./...` 之后必须检查 `antlr` 是否被抬高；被抬高就钉回。
- 升级 `zeromicro/ddl-parser` 或 `goctl` 之前，先确认新版本是否已适配 `antlr v1.4.x`；未适配前不要单独升 `antlr`。
- 这类「上游生成代码依赖旧 API」的升级失败，应保留在 `go.mod` 的钉版，而不是回滚整个模块的更新。

## 五、变更记录

| 日期 | 内容 |
|---|---|
| 2026-10-22 | 记录问题、根因与钉版修复 |
| 2026-10-22 | 钉版后 `GOWORK=off go build ./...`、`go vet ./...`、`go test -short ./...` 全部通过；状态改为已修复 |
