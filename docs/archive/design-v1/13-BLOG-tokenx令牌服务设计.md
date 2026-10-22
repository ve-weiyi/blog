# blog 博客系统 — 令牌服务（tokenx）设计

初稿：2026-10-21　·　最近更新：2026-10-21

## 一、定位与边界

tokenx 是**令牌服务**，负责令牌的签发、校验、刷新、撤销与会话生命周期；它不是登录流程、不是权限系统、不是身份标识系统，也不负责前端实现。

| 关注点 | 归属 |
|---|---|
| 登录方式、第三方授权、注册、RBAC | 不在本文范围 |
| 用户 ID、游客 ID、设备 ID 的形态与签发 | 《12 用户与游客身份标识》 |
| 不可信输入、降级方向 | 不在本文范围 |
| 错误码、中间件装配 | 《07 错误码与中间件》 |
| 部署、密钥与凭据管理 | 《05 部署与运维》 |
| 具体实现方案与实施步骤 | [tokenx 重构实现方案](../../feature/2026-10-20-tokenx重构设计.md) |

本文**取代旧令牌设计中关于形态、吊销机制与客户端存储的描述**；登录方式、第三方授权与 RBAC 仍以现有认证设计为准。

---

## 二、设计目标与约束

### 目标

- 令牌形态与长度符合社区惯例，不自定义密码学算法；
- 撤销立即生效，不等待令牌自然过期；
- 刷新令牌轮换，重放可检测、可止损；
- 支持单点登录与多端登录；
- 浏览器端不把长期凭据暴露给 JavaScript；
- 在 app/admin 之间保留有意设计的形态差异，避免单一路径；
- 不依赖历史数据兼容，允许直接替换旧令牌。

### 约束

- 所有 access token 通过 `Authorization: Bearer` 发送；
- 生产 access token 不使用自定义 token 请求头；
- 不在运行时随机切换令牌实现；
- 不引入自研密码学原语；
- 不把角色/权限写进令牌。

---

## 三、核心决策

| 项 | app | admin |
|---|---|---|
| 客户端形态 | Web SPA 直接调用 API | BFF + HttpOnly Cookie |
| access token | opaque reference，`at_` + 43 字符 | JWT HS256，约 380 字符 |
| refresh token | opaque reference，`rt_` + 43 字符 | opaque reference，`rt_` + 43 字符 |
| 登录模式 | 多端 | 单点 |
| access TTL | 120 分钟 | 120 分钟 |
| refresh idle | 7 天 | 7 天 |
| refresh absolute | 30 天 | 30 天 |
| rotation grace | 30 秒 | 30 秒 |
| access 存储 | 浏览器内存 | BFF 服务端 |
| refresh 存储 | HttpOnly Cookie | BFF 服务端 / HttpOnly Cookie |

未来原生 App：Authorization Code + PKCE，access 内存，refresh 安全存储，Bearer；不走 Cookie。

---

## 四、信任模型与威胁

### 4.1 Bearer 的本义

Bearer 是**持有即有权**的传输方案，不是令牌格式。无论 token 是 opaque 还是 JWT，只要被放到 `Authorization: Bearer`，一旦泄露，持有者就能使用。

因此安全不能只依赖“令牌不可读”：

- TLS 是前提；
- access token 短命（本项目为 120 分钟）并支持立即撤销；
- refresh token 轮换，旧 token 重放要能止损；
- 浏览器端避免长期凭据进入 JS；
- 高价值场景可进一步使用 DPoP/mTLS。

### 4.2 主要威胁与应对

| 威胁 | 应对 | 残余风险 |
|---|---|---|
| access token 被窃 | 短 TTL、session 撤销、审计 | 120 分钟窗口 |
| refresh token 被窃 | 轮换、family 重放检测、30 秒 grace | grace 窗口内的重放 |
| XSS 读取 token | app access 只存内存；refresh 仅 HttpOnly Cookie；严格 CSP | XSS 仍可以用户身份发请求 |
| CSRF | refresh 端点 Origin/CSRF 校验；SameSite | 跨站配置错误时仍有风险 |
| 设备标识伪造 | 只使用身份层可信设备标识；设备绑定仅作 defense-in-depth | 设备绑定不是强认证 |
| BFF Cookie 被利用 | SameSite + CSRF + BFF 服务端校验 | 浏览器端仍需 CSP |
| Redis 不可用 | 会话校验 fail-closed | 认证不可用 |

### 4.3 设备绑定

设备绑定的对象是**身份层签发的可信设备标识**，不是客户端随意填写的请求头。它用于降低“令牌被搬到另一设备重放”的风险，但不是强认证：

- 设备标识本身不是秘密；
- 真正的发送方约束需要 DPoP/mTLS；
- 当前生产不引入 DPoP，保留为可选/测试能力。

---

## 五、令牌形态

### 5.1 app：opaque reference token

- 32 字节随机数，base64url 编码，43 字符；
- access 前缀 `at_`，refresh 前缀 `rt_`，总长 46；
- 不携带 uid/sid/claims；服务端按 token 哈希查找会话；
- token 哈希带类型域（access/refresh），防止混用；
- 服务端只保存哈希，不保存明文；
- 优点：短、不可读、无签名密钥、撤销完全以会话为准。

### 5.2 admin：JWT HS256 access

- 标准 JWT 三段式；
- header：`alg=HS256`、`typ=at+jwt`；
- claims：`iss`、`sub`、`sid`、`did`、`jti`、`iat`、`exp`；
- 不使用自定义 `use` claim；access 类型由 header `typ=at+jwt` 表达；
- 签名与验签共用 32 字节以上 secret，只分发给 admin-api 及其验签方；
- access 校验后仍查会话，撤销立即生效。

选择 HS256 的代价：**验签方同时具备签发能力**。当前 admin-api 是唯一的签发与验签方，secret 的暴露面可控；若将来出现独立验签方（网关、BFF、其他服务）或需要按 `kid` 平滑轮换，应改回非对称签名，而不是继续分发共享 secret。

### 5.3 admin refresh：opaque

admin 的 refresh 不使用 JWT，而是 opaque `rt_`：

- refresh 只在 token endpoint 使用；
- 轮换、重放检测、family 撤销都以服务端状态为准；
- 避免把长生命周期凭据做成可读 JWT。

### 5.4 不进入生产的形态

- 自定义 HMAC 信封；
- PASETO v4.local；
- 非对称签名的 JWT（ES256/RS256）；
- 这些作为可选实现，由测试矩阵覆盖，不作为生产默认。

### 5.5 长度预算

| 令牌 | 预算 |
|---|---:|
| app access | 46 |
| app/admin refresh | 46 |
| admin access | 约 380 |
| HTTP header | 8KB/字段 |
| Cookie | 4KB/name+value |
| 存储字段 | ≥512 字符，不按固定长度设计 |

---

## 六、客户端形态与传输

### 6.1 app：SPA 直连，不使用 BFF

- access token 只放浏览器内存；
- refresh token 只放 `HttpOnly + Secure + SameSite` Cookie；
- 禁止 localStorage/sessionStorage/IndexedDB 存 token；
- 登录使用 OAuth 2.1 Authorization Code + PKCE，精确 redirect URI、state/nonce；
- refresh 端点必须做 CSRF/Origin 校验；
- 严格 CSP，禁止 inline script，第三方脚本使用 SRI；
- 登出删除 Cookie 并撤销会话。

**为什么不上 BFF**：app 是公开、读多写少的站点；SPA 直连部署更简单、少一跳延迟。代价是 access token 暴露给 JavaScript，XSS 可读取；因此 CSP 与 120 分钟 TTL 的残余风险必须被接受。若后续风险不可接受，应改为 BFF，而不是继续加长 token。

### 6.2 admin：BFF + HttpOnly Cookie

- 浏览器只拿 BFF 会话 Cookie，不接触 access/refresh token；
- BFF 在服务端保存 token，并负责刷新；
- BFF → admin API 使用 Bearer；
- 需要 CSRF 防护；
- admin 是高权限后台，采用更强的浏览器边界。

### 6.3 原生 App（未来）

- Authorization Code + PKCE；
- 系统浏览器/ASWebAuthenticationSession，不用嵌入式 WebView；
- access 内存，refresh Keychain/Keystore；
- Bearer 调用 API。

### 6.4 传输约定

- access token：`Authorization: Bearer`；
- refresh token：请求体或 HttpOnly Cookie，不走 Bearer；
- 不使用自定义 token 请求头；
- 自定义头只承载设备 ID、请求 ID 等辅助元数据；
- token 不放 URL、不写日志；
- 响应使用 OAuth 风格字段：`access_token`、`token_type`、`expires_in`、`refresh_token`、`refresh_expires_in`。

---

## 七、会话模型与生命周期

### 7.1 会话

一次登录产生一个会话，绑定：

- 用户；
- 设备；
- 登录族（family）；
- 客户端标识；
- access/refresh 过期时间；
- 绝对过期时间；
- 最近使用时间。

同一用户 + 设备同时只保留一个活跃会话。

### 7.2 单点与多端

- 多端：不同设备各自保留会话；同设备重新登录替换旧会话；
- 单点：新登录撤销该用户全部旧会话。

模式是**产品策略**，不是两套令牌机制。

### 7.3 刷新轮换与 family

- 每次刷新签发新的 access/refresh，旧 refresh 立即失效；
- 同一登录链共享 family；
- 旧 refresh 在 grace 外重放 → 撤销整个 family；
- grace 内重放 → 返回同一轮换结果，避免并发刷新误杀；
- grace 默认开启，无需额外密钥配置：grace payload 用旧 refresh token 派生的密钥加密，同一 token 在任何副本上都能解出，Redis 单独泄露无法解密；
- 刷新不能突破 absolute lifetime。

### 7.4 生命周期

- access：120 分钟；
- refresh idle：7 天未使用过期；
- refresh absolute：30 天必须重新登录；
- rotation grace：30 秒；
- 所有过期时间由服务端判定，客户端时间不可信。

### 7.5 撤销

- 单会话撤销：登出当前设备；
- 按设备撤销：踢掉某设备；
- 全部撤销：改密、停用、注销、管理员操作。

撤销立即生效：access 校验每次都读会话状态；refresh 校验读会话与 family 状态。

### 7.6 存储模型

会话状态由 tokenx 自己的存储维护：

- 与会话一条记录，独立过期；
- 按用户、设备、token 哈希、family 建索引；
- 不采用“按用户一个版本号”的单一吊销机制；
- 不依赖过期字段扫描：会话记录自身带 TTL；
- 读路径只返回未过期会话；
- 存储实现可替换（Redis / 内存），生产使用 Redis。

---

## 八、数据流

### 8.1 签发

登录成功后，tokenx 依据用户、设备与客户端标识创建会话和 family，签发 access/refresh，并把会话与索引写入存储。签发是登录流程的最后一步，不参与登录方式本身的判定。

### 8.2 校验

access 校验分两条路径：

- opaque：token 哈希 → 会话 → 检查类型、过期、设备、会话状态；
- JWT：验签 → `sid` → 会话 → 检查 claims 与会话一致、类型、过期。

两条路径最终都落到**服务端会话**，因此撤销立即生效。

### 8.3 刷新

refresh 校验通过后：

1. 检查 idle 与 absolute；
2. 在校验和写入之间保证只有一个成功轮换；
3. 新会话继承 family；
4. 旧 refresh 失效，并写入 grace 结果与重放墓碑；
5. grace 外重放撤销 family。

并发刷新是重点：必须保证“一个 refresh 只产生一个有效后继”，同时给客户端一个短暂的 grace 窗口。

### 8.4 撤销

按会话、设备或用户删除会话与索引。撤销是幂等的；重复撤销不报错。

### 8.5 依赖不可用

- 会话存储不可用：**fail-closed**，拒绝认证；
- 审计/指标不可用：不影响认证，记录降级；
- 签名密钥缺失或无效：服务启动失败，不进入降级运行。

---

## 九、可选技术与多样性

生产保持两条组合：

- app：opaque + SPA 直连；
- admin：JWT HS256 + BFF。

多样性保留在**可选实现与测试**中：

- 自定义 HMAC 信封（已实现，由测试矩阵覆盖）；
- 非对称签名的 JWT（ES256/RS256，未实现；出现多验签方时引入）；
- PASETO v4.local（未实现）；
- DPoP（发送方约束）；
- 不同存储实现（内存/Redis）。

约束：

- 可选实现可按需装配，但生产默认不启用；
- 自研仅限 token 信封/claims，底层使用标准 HMAC-SHA256/ECDSA/Ed25519；
- 生产默认只用标准 JWT 与不透明令牌，不启用自研信封；
- 不发明密码学算法；
- 可选实现必须通过同一套契约与矩阵测试；
- 验证通过自动化测试完成，不以生产命令或手工脚本替代。

---

## 十、备选方案与取舍

| 方案 | 结论 | 理由 |
|---|---|---|
| 全站统一 opaque | 未采用 | 失去标准 JWT 形态与多样性 |
| 全站统一 JWT | 未采用 | app 需要更短、更易撤销的 reference token |
| admin 使用 HS256 | 已采用 | admin-api 是唯一签发与验签方，配置与运维更简单；代价是验签方持有签名密钥，出现多验签方时应改回非对称 |
| refresh 也用 JWT | 未采用 | refresh 只在 token endpoint 使用，opaque 更短，状态仍由服务端掌握 |
| 用户级版本号吊销 | 未采用 | 无法表达设备、family、单会话撤销；新设计以会话为真相源 |
| 用户 hash + 过期字段扫描 | 未采用 | 清理复杂；per-session 记录 + TTL 更简单 |
| 滑动 refresh TTL | 未采用 | 可无限续期；改为 idle + absolute |
| 严格重放即撤销、无 grace | 未采用 | 并发刷新会误杀；30 秒 grace 更符合实际 |
| app 上 BFF | 暂未采用 | 公开读多写少站点，保留 SPA 直连与部署简单性；以 CSP/HttpOnly refresh 控制风险 |
| admin 不上 BFF | 未采用 | 高权限后台需要更强的浏览器边界 |
| token 加 `blog_` 前缀 | 未采用 | 用 `at_`/`rt_` 已足够识别类型 |
| DPoP/mTLS 进生产 | 暂未采用 | 复杂度和客户端改造大；保留为可选/未来能力 |

---

## 十一、与其他文档的关系

- 登录方式、第三方授权、RBAC、不可信输入与降级方向不在本文重复。
- 设备 ID 的形态与签发以《12 用户与游客身份标识》为准；tokenx 只消费可信设备标识，不自行定义设备身份。
- 错误码与中间件装配以《07 错误码与中间件》为准。
- JWT 密钥、Cookie、TLS、Redis 的部署要求以《05 部署与运维》为准。
- 实现方案与步骤：见 [tokenx 重构实现方案](../../feature/2026-10-20-tokenx重构设计.md)。

---

## 十二、修订记录

| 日期 | 内容 |
|---|---|
| 2026-10-21 | 初稿。确立 opaque/ES256 双形态、app SPA 直连与 admin BFF、refresh family/idle/absolute/grace、per-session 存储与安全边界 |
| 2026-10-21 | admin access 由 ES256 调整为 HS256；移除非对称签名、KeySet 与 `kid` 轮换，签发与验签共用 secret |
| 2026-10-21 | grace 默认开启；grace payload 密钥由旧 refresh token 派生，删除额外密钥配置与关闭路径 |
