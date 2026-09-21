# blog-admin 与 blog-app 框架层对齐审查报告

> 日期：2026-09-17
> 范围：`blog-admin`（Vue3 + Vite + TS + Element Plus）+ `blog-app`（Vue3 + Vite + TS + Naive UI）
> 方式：双工程分层对照排查（request / stores / router / api / plugins / 构建配置 / 死代码），
> 契约类结论逐条对拍后端 `blog-cloud` 源码验证；死代码结论以全仓引用计数（含生成的 `components.d.ts`）验证
> 性质：**日期快照**。结论对应上述日期的代码状态，落地后以代码为准。

---

## 〇、结论概览

两个前端是**故意不同 UI 栈**的姊妹工程，但它们在**同一个后端契约**上分叉了，而分叉点恰好落在鉴权与错误处理这条最要命的链路上。当前状态：

1. **契约层分叉** —— 三个已确认的真 bug，其中两个导致登录态机制形同虚设（P0，**均已修复**，见 §一 落地状态）
2. **框架机制该共享而未共享** —— HTTP 客户端、AuthStorage、STOMP、api 层 16 个同构模块（P1）
3. **各自内部背着一批模板残留死代码** —— 不影响行为，但持续制造噪音（P2）；其中两个 app 真 bug **已修复**
4. **api 层应当 codegen 却手写** —— `generate_ts.sh` 已写好但空转，是 142 处 / 51 处 URL 硬编码的根因（P3）

对齐方向不是"把两边改成一样"——UI 组件、样式主题、路由骨架、鉴权策略**不该**统一。该统一的是**契约与传输层**。

---

## 一、契约层：必须对齐（3 个已确认 bug，均已修复）

### 落地状态（2026-09-17 复核）

| 条目 | 状态 |
|---|---|
| §1.1 前端枚举不对齐后端 | ✅ 已修复 —— 两端 `ApiCodeEnum` 已与 `bizcode` 一一对应 |
| §1.2 `msg` → `message` | ✅ 已修复 —— 后端响应体为 `message`，两端不再消费后端文案，`backend.md` 已同步 |
| §1.3 admin 刷新传空 user_id | ✅ 已修复 —— 改从 `AuthStorage.getUid()` 取，回填加兜底 |

### 1.1 前端错误码枚举不等于后端 —— token 刷新在两端都是死代码 ✅ 已修复

**当时的缺陷**：枚举与后端脱钩，而 `refreshTokenOnce` 在两个工程各自**只有一个调用点**，
即响应拦截器的"access 失效"分支 —— 分支条件永远等不到，刷新链路整条是死代码。
两端错法不同：blog-admin 的值对得上、**语义挂反了**（把"登录已过期"当成"refresh 失效"直接跳登录），
blog-app 的值整个抄自 HTTP 状态码（400/401/402/403），后端从不发这些值 ——
真正过期时落进 `default`，只弹错、不刷新、不登出；反而"参数格式错误"会误触发一次 token 刷新。

**修复**：两端 `src/enums/api.ts` 改为与 `blog-cloud/infra/biz/bizcode` 一一对应的字符串标识（24 个，
两端逐行相同），分发语义统一为 `LOGIN_EXPIRED → 刷新并重试`、`UNAUTHENTICATED → 放弃并登出`、
`PERMISSION_DENIED / ROLE_MISMATCH / OPERATION_NOT_ALLOWED → 重载权限快照后提示`。
两个鉴权中间件的 `ErrTokenExpired` 分支（`blog-cloud/api/admin/internal/middleware/adminauth_middleware.go:51-56`、
`blog-cloud/api/app/internal/middleware/userauth_middleware.go:51-56`）产出 `LOGIN_EXPIRED`，其余校验失败产出 `UNAUTHENTICATED`。
标识取值与 HTTP 状态的对应关系见 `docs/design/07-BLOG-错误码与中间件.md` §1.4。

### 1.2 响应字段名 `msg` vs `message` —— 两个前端的后端错误提示全是兜底文案 ✅ 已修复

**当时的缺陷**：后端响应体字段是 `message`，而 `.claude/rules/backend.md` 把统一响应格式写成了 `{code, msg, data}`，
两个前端照文档实现 `const { code, msg } = response.data` —— `msg` 恒 `undefined`，
所有错误提示永远走兜底串，后端的真实错误描述被静默丢弃，排查线上问题时前端看不到任何有效信息。

**修复**：`backend.md` 已改正为 `message`；两端 `src/` 内再无 `.msg` 读取。
分发改为按 `ApiCodeEnum` 逐个标识给**客户端自有文案**，不再消费后端 `message` ——
契约是标识，文案不稳定、不作为分发依据；`message` 字段仍在响应体中，供排障阅读。

### 1.3 blog-admin 刷新 token 传空 user_id ✅ 已修复

**当时的缺陷**：admin 从 `userInfo.value.user_id` 取 uid，而 `userInfo` 初始化为 `{} as UserProfile`、靠
`getUserInfo()` 异步回填 —— 硬刷新后是 **`undefined`**。后端 `tokenx.manager.Refresh` 第一句就是
`validateIdentity`：`userID == ""` 直接返回 `tokenx: userID must not be empty`
（`blog-cloud/infra/tokenx/manager.go:71-76`，未走到 refresh token 校验）。该错误不是 `BizError`，
经响应出口落 `INTERNAL_ERROR`，前端拦截器 catch 后走 `endSession` ——
**持有有效 refresh token 也被强制登出**，"记住我"退化成"重新输密码"，
`refreshTokenOnce` 的单飞与 `WeakSet` 防重试保护全部失效。

**修复**：改从 `AuthStorage.getUid()` 取（`blog-admin/src/stores/user.ts:191`）——
凭据只能来自 `AuthStorage`：uid 与两个 token 由 `setTokens` 成对写入、由 `clearAuth` 成对清理，
同一函数上一行的 `getRefreshToken()` 就是从存储取的；`userInfo` 是展示态缓存，不是凭据来源。
同时把回填改为 `res.data.user_id || AuthStorage.getUid()`，避免后端某日不回填该字段时把已存 uid 覆盖成空串。

---

## 二、可以对齐的框架机制（按收益排序）

| # | 机制 | blog-admin | blog-app | 对齐做法 |
|---|---|---|---|---|
| 1 | **HTTP 客户端** | `src/utils/request.ts`（141 行） | `src/utils/request.ts`（135 行） | 两者 **95% 逐行相同** —— 同一套 device-token SHA-256 签名、同一套 `retriedConfigs` 单飞重试、同样的超时/网络错误文案分支。抽 `createHttpClient({ basePrefix, auth, notify })` |
| 2 | **api/ 目录 + barrel** | 31 个模块，`src/api/index.ts` 31 条命名导出 | 18 个模块，18 条命名导出 | **16 个同名 API 命名空间**（`AuthAPI`/`GuestAPI`/`MeAPI`/`UploadAPI`/`WebsocketAPI`/`ArticleAPI`/`CategoryAPI`/`TagAPI`/`CommentAPI`/`MessageAPI`/`TalkAPI`/`AlbumAPI`/`PhotoAPI`/`ConfigAPI`/`FriendAPI`/`PageAPI`），目录层级也一致（`account/` `content/` `discussion/` `media/` `site/` `common/`），差异**只有 URL 前缀**。`src/api/common/websocket.ts` 除前缀外逐字节相同 |
| 3 | **AuthStorage** | `src/utils/auth.ts` + `src/utils/storage.ts`（双类，含 `rememberMe` 双存储策略） | `src/utils/auth.ts`（单文件，纯 localStorage） | 语义完全一致，实现三处分叉：① rememberMe 双存储 vs 无；② `clearAuth` 精准删 key vs `localStorage.clear()`（`blog-app/src/utils/auth.ts:54`，会清掉同源下其他应用的存储）；③ STORAGE_KEYS 位置（admin 在 `constants/index.ts:9-40`，app 内联在 `utils/auth.ts`） |
| 4 | **STOMP 客户端** | `src/hooks/websocket/core/useStomp.ts`（363 行，参数化 options + 订阅管理，可复用） | 在 `src/components/ChatRoom/index.vue:247-262` 组件内手搓 `new Client()` | blog-app 应复用同一份 `useStomp`。**附注**：两者重连哲学不同 —— admin 关掉 stompjs 内置重连、自己手写指数退避 + 超时 + 手动断开标志；app 直接用 `reconnectDelay: 5000` 交给库。统一时需先定策略，倾向于**用库内置能力** |
| 5 | **mock 装配** | `mock/base.ts`（7 行）+ 11 个 mock | `mock/base.ts`（7 行）+ 7 个 mock | `mock/base.ts` **逐字节相同**（diff 为空）；6 个同名 mock 文件（`account`/`common`/`content`/`discussion`/`media`/`site`） |
| 6 | **全局 d.ts 位置** | 顶层 `blog-admin/types/`（`auto-imports`/`components`/`env`/`global`/`modules`/`router`.d.ts） | `blog-app/src/types/` | 统一到 `src/types/`（与 `frontend.md` 的 `src/types/` 目录约定一致） |
| 7 | **package.json scripts** | `build:preview` = `vite build --mode preview`（不做类型检查） | `build:preview` = `vue-tsc --noEmit && vite --mode preview build` | 根 `Makefile` 已按对称假设驱动两边（`FRONTENDS := blog-admin:9521 blog-app:9520`，`make test` → `pnpm test`，`make preview` → `pnpm build:preview && pnpm preview`），但脚本语义不对称：① app 的 `dev`/`test`/`preview` 带 `--host`，admin 不带；② admin 的 `build:preview` 不校验类型，app 会因 TS 报错直接失败；③ app 的 `prod` 与 `build` 重复度极高 |
| 8 | **TS 严格度** | `tsconfig.json` `strict: true` | `strict: false`，且 `strictNullChecks`/`strictFunctionTypes`/`strictBindCallApply`/`strictPropertyInitialization`/`noImplicitAny` **逐项显式关掉** | 与 `.claude/rules/frontend.md`"TypeScript 严格模式"相悖。app 已积累大量 `any`/非空断言才敢关，是 P3 的长期收敛项 |

---

## 三、冗余清单

### 3.1 两端重复（可收敛为共享包）

| 项 | 说明 |
|---|---|
| `mock/*.mock.ts` | 6 个同名文件 |
| api 层 | 16 个同构模块 + 同构 barrel + 硬编码 URL 前缀（admin `/admin-api/v1` 142 处，app `/api/v1` 51 处） |
| `src/api/types.ts` | admin 1534 行 / app 690 行，**63 个同名类型**（`LoginResp`/`Token`/`RefreshTokenReq`/`UserInfoVO`/`UserInfoExt`/`ListQuery`/`ListResult`/`PageVO`/`UploadFileReq`/`WebsiteConfigVO`/`EmptyReq`/`EmptyResp`…）。共同的 63 个恰好是**鉴权/会话/上传/用户**这条横切主线，是最该抽的部分 |

**以下两项形似冗余，实为有意分化，不要强行统一**：

- `APP_NAME`：admin `"blog"`、app `"blog-web"`（`blog-admin/src/utils/auth.ts:7`、`blog-app/src/utils/auth.ts:4`）。
  该值随 `App-Name` 请求头下发，用于区分客户端，本就应当不同
- **token 请求头名不同**：admin 发 `Authorization`（`blog-admin/src/utils/request.ts:20`），
  app 发 `Token`（`blog-app/src/utils/request.ts:13`）。这不是漂移 —— 两个网关中间件分别只认一个：
  `adminauth_middleware.go:34` 读 `bizheader.HeaderAuthorization`，
  `userauth_middleware.go:35` 读 `bizheader.HeaderToken`。
  要收敛应落在后端 `bizheader` 层；前端侧只能做成"每客户端一个请求装饰器"

### 3.2 api 层应当 codegen，`generate_ts.sh` 目前空转

`protocol/api/generate_ts.sh:28` 把 goctl 生成的 TS 输出到 `blog-cloud/api/<service>/ts`：

- 该目录**不存在**
- 两个前端**均未引用**
- 该路径也**未加入 `.gitignore`**，即"从未被运行过"而非"被忽略"

api 层目前 100% 手写，模式高度机械（`XxxAPI` 对象字面量 + `request({url, method, params|data})` + `Promise<ApiResponse<T>>`），
是 codegen 的典型场景。**这才是 URL 前缀到处硬编码的根因** —— 应决定：真正跑起来，还是删掉脚本。

### 3.3 blog-admin 内部死代码

引用计数均为 0（含生成的 `types/components.d.ts` 在内全仓检索）：

| 位置 | 现状 |
|---|---|
| `src/composables/usePageTable.ts` | 仅自身定义 + `composables/index.ts:3-4` barrel 导出 |
| `src/composables/useTableSelection.ts` | 仅自身定义 + barrel 导出 |
| `src/composables/sse/`（5 文件，含 ~300 行 `useSse.ts`） | 整棵子树只被自己引用；`setupSse()` 从未被调用 |
| `src/components/Pagination/` | 零引用（`PageContent.vue` 内联了 `<el-pagination>`） |
| `src/components/OperationColumn/` | 零引用（内部含一段用 `getElementsByClassName` 全局测量按钮宽度的 hack） |
| `src/directives/permission/index.ts:42` `hasRole` | 只有定义，未注册未使用（`directives/index.ts` 只注册了 `hasPerm`） |
| `types/modules.d.ts` 的 `sockjs-client` 声明 | 依赖已在 `package.json` 中移除，声明成为孤儿 |
| 依赖 `vue-draggable-plus` | `src/` 零引用 |
| 依赖 `@wangeditor-next/editor` `@wangeditor-next/editor-for-vue` | `src/` 零引用（实际使用 `md-editor-v3`） |

**权限判断有三种并行实现**：

| 实现 | 位置 | 使用情况 |
|---|---|---|
| `v-hasPerm` 指令 | `src/directives/permission/index.ts` | 全仓仅 **3 处**，且全部在 CURD 的 `PageContent.vue:16,38,167` 内，写法都是 `btn.perm ?? '*:*:*'`；**业务视图零使用** |
| `hasPerm()` 函数 | `src/utils/auth.ts:97` | CURD 实际调用的这份（`PageContent.vue:328` 导入） |
| `hasButtonPerm()` 私有函数 | `src/components/CURD/PageContent.vue:389` | 组件内私有，包装 `hasPerm()`，用于行内操作按钮的 `:disabled` |

即指令被写出来后又被同一组件的 script 内调用取代，三条路径最终都收敛到 `hasPerm()`。

**自动导入产物停产但在用**：`vite.config.ts:79` 与 `:91` 均为 `dts: false`，
但 `types/auto-imports.d.ts`（991 行）、`types/components.d.ts`、`.eslintrc-auto-import.json` 仍提交在库中
且**仍被消费**（`tsconfig.json` 的 `include` 收录 `types/**/*.d.ts`；`eslint.config.ts:12` 读取该 json）。
属于"停产但在用的产物"：新增的自动导入符号不会进这两份 d.ts，一旦用到，
`pnpm build` 第一步 `vue-tsc --noEmit` 就会失败。

### 3.4 blog-app 内部死代码 / 冗余

| 位置 | 现状 |
|---|---|
| `src/stores/plugins/index.ts` `resetSetupStore` | `setupSyntaxIds = ["setup-store"]` **匹配不到任何 store**（三个 store 全是 options 风格，已自带 `$reset`），却为此引入 `lodash-es` 的 `cloneDeep` |
| 两套音乐播放器 | `components/MusicPlayer/`（aplayer 封装）与 `components/zw-player/`（`player.vue` 760 行 / 24K + 独立 `api/` + 11 张 PNG，整目录 192K）。`App.vue:22` 已把 `MusicPlayer` 注释掉（`:24` 使用 `Player`），但两者都仍在全局注册，`aplayer` 与 `APlayer.min.css` 仍被打进包 |
| 依赖 `tocbot` | `src/` 零引用 |
| 依赖 `crypto-js` | `src/` 零引用（device token 走 Web Crypto `crypto.subtle`） |
| `VITE_STORAGE_PREFIX` | 4 个 env 文件均有定义，`src/` **零引用**；`utils/auth.ts` 硬编码 `blog-web:` |
| `src/types/app.d.ts` 的 `App.Service.*` | 零引用 |
| `src/types/common.d.ts` 的 `CommonType` | 零引用（全文件仅 3 行） |
| `uno.config.ts:26` | `primary: "var(--el-color-primary)"` —— 从 admin 抄来的。**blog-app 是 Naive UI，该变量在本仓库从未定义**（admin 那份 `uno.config.ts:43` 才有意义），导致所有 `text-primary`/`bg-primary` 工具类解析到未定义变量 |

**两个真 bug（非死代码，是行为错误），均已修复**：

1. ✅ `blog-app/src/permission.ts:41` —— `if (userStore.userInfo.user_id !== undefined) return true;`
   而 `userInfo` 初始化为 `{ user_id: "", ... }`（`stores/modules/user.ts:54-69`），
   故条件**恒为真**，`await userStore.getUserInfo()` 永远不执行。
   守卫里的"凭证失效 → 登出"分支是**不可达代码**，硬刷新后 `userInfo` 永远不会被回填。
   **修复**：改为真值判断 `if (userStore.userInfo.user_id)`；`getUserInfo()` 失败分支的
   `logout()` 自身也会带着失效凭证失败并中断导航，故再包一层 `try/catch` 兜底 `forceLogOut()`
2. ✅ `blog-app/src/App.vue:7-9` —— `<keep-alive>` 无 `include`/`max`，且以 `:key="route.path"` 缓存，
   每访问一篇 `/article/:id`、`/talk/:id`、`/album/:albumId` 就永久缓存一个组件实例，单调增长。
   **修复**：加 `:max="8"`（Vue 3.5 runtime 的 KeepAlive 为真 LRU：命中提权、插入超限淘汰最久未用）。
   未走 `include` 策展的原因：`include` 匹配组件名，而 SFC 的 `__name` 取文件名，
   `views/Home/index.vue`、`views/Archive/index.vue` 等一律推导为 `index`，无法区分，
   要策展必须先给每个待缓存视图补 `defineOptions({ name })`

**其他框架性缺陷**：

- 无 `NConfigProvider`（全仓零命中）：Naive UI 组件跑默认亮色主题，与 `theme-shoka.scss`
  的 CSS 变量暗色主题是两套互不知情的系统
- 路由无 404 兜底：`src/router/routes/index.ts` 末尾 `{ path: "/:catchAll(.*)", redirect: "/404" }` 被注释掉
- 两处绕过整个请求层：`components/zw-player/api/music.ts` 与 `components/AiAssistant/index.vue:275`
  各自裸 `fetch()`，不走 `utils/request.ts`，因此**没有鉴权头、没有设备签名、没有统一错误提示**
- 图标管线两套并行：`unplugin-icons`（编译期 `i-*`）与 `vite-plugin-svg-icons`（运行时 sprite + 手写 `SvgIcon`），
  两者都指向 `src/assets/icons`，实际只用了后者

---

## 四、对齐边界：什么该共享，什么不该

这是本次审查最关键的判断。两端**技术栈故意不同**（Element Plus vs Naive UI），必须二分处理。

### 该共享（契约 + 传输层，与 UI 无关）

- 错误码枚举与响应字段契约 —— 直接对齐 `bizcode`，避免再次手抄（**已落地**，见 §1.1 / §1.2）
- `createHttpClient` + 拦截器策略（刷新 / 重试 / 登出）
- `AuthStorage` + 设备指纹（device-token 签名算法）
- STOMP `useStomp`
- 63 个横切 DTO（鉴权 / 会话 / 上传 / 用户）
- `mock/base.ts` 与 mock 装配方式

### 不该共享（各自的领域形态本就不同）

| 项 | 理由 |
|---|---|
| UI 组件、样式体系、Uno theme map | 两套 UI 库互不兼容。`blog-app/uno.config.ts:26` 抄 `--el-color-primary` 就是这个错误做法的实例 |
| 路由骨架 | admin 是**后端动态菜单驱动**（`stores/permission.ts` 的 `import.meta.glob("../views/**")` 组件解析 + `transformRoutes`），app 是 18 条静态路由、无鉴权守卫 |
| 鉴权策略 | admin 有 rememberMe 双存储 + 权限快照 + `v-hasPerm`；app 无权限模型。**不应为"统一"给 app 套上 admin 的 permission store** |

### 附带的方向性结论

api 层应由 `protocol/*.api` **单向生成**，而非两端各手写一份。这也顺带解决
`VITE_APP_BASE_API` 在两边都"定义了但 axios 不用"的问题
（admin 仅 `composables/sse/useSse.ts:39` 使用，app 仅 mock 插件使用，
其余全部硬编码前缀）。

---

## 五、优先级建议

| 优先级 | 内容 | 涉及文件 | 理由 |
|---|---|---|---|
| **P0** | ① ✅ 两端 `ApiCodeEnum` 对齐 `bizcode`<br>② ✅ `msg` → `message`（两端 request.ts + `backend.md`）<br>③ ✅ admin 刷新改用 `AuthStorage.getUid()` —— **P0 全部落地** | — | 三项均为登录态/错误提示的可用性缺陷，改动小、相互独立 |
| **P1** | 抽共享包：`createHttpClient` / `AuthStorage` / `useStomp` / 错误码常量 / 63 个横切 DTO | 新建包 + 两端改造 | 消除最大的重复面，且完全不触碰 UI |
| **P2** | 清理死代码（admin：`composables/sse` + `usePageTable` + `useTableSelection` + `Pagination` + `OperationColumn` + `hasRole` + 2 个无用依赖；app：`resetSetupStore` + `MusicPlayer` + `tocbot` + `crypto-js` + 2 个死类型命名空间） | ~20 个 | 降低噪音，不改变行为，可分批独立验证 |
| **P2** | ✅ 修两个 app 真 bug：`permission.ts:41` 恒真判断、`App.vue` 无界 keep-alive | 2 个 | 行为错误，与死代码清理可并行 |
| **P3** | ① 决定 `generate_ts.sh` 生死（走 codegen 或删脚本）<br>② app 开 `strict`<br>③ 两端 scripts 对齐（`--host`、`build:preview` 类型检查）<br>④ admin 恢复 dts 生成或删除停产产物 | 多点 | 结构性收敛，工作量最大，需单独评审 |

### 与既有审查的前后关系

`docs/review/2026-09-15-blog-cloud工程现状审查报告.md` §1.1 已提出"两个前端跑 `vue-tsc --noEmit`"的 CI 缺口，
至今未落地。本次补充：**admin 的 d.ts 自动导入产物已停产**（§3.3），
一旦 CI 加上 `vue-tsc`，新增的自动导入符号会立即触发失败 —— 两件事需一并处理。

---

## 六、已核实的验证方式（供复核）

| 结论 | 验证手段 |
|---|---|
| 响应体字段为 `message` | `grep -rn 'json:"msg"' blog-cloud/` 零命中；`responsex.Body` 定义直接阅读 |
| `refreshTokenOnce` 仅一个调用点 | 全仓 `grep -rn "refreshTokenOnce"`，两端各命中定义 + `request.ts` 拦截器一处 |
| 死代码引用数为 0 | 全仓 `grep -rn`，含生成的 `types/components.d.ts`；`Pagination`/`OperationColumn` 仅在该生成文件出现 |
| `v-hasPerm` 仅 3 处使用 | 全仓 `grep -rn "v-hasPerm"` → 除指令注册注释外，3 处全在 `PageContent.vue`（:16 :38 :167），业务视图零命中 |
| 各文件行数 | `wc -l` 实测：admin request.ts 141、app request.ts 135、api/types.ts 1534 / 690、`useStomp.ts` 363、`useSse.ts` 321、`auto-imports.d.ts` 991、`common.d.ts` 3、`zw-player/player.vue` 760 |
| `mock/base.ts` 完全相同 | `diff` 输出为空 |
| `generate_ts.sh` 从未运行 | 目标目录不存在 + 未加入 `.gitignore` + 前端零引用 |
| 未使用依赖 | `grep -rl "<dep>" src/ mock/ types/ vite.config.ts` 零命中 |
| `uno.config.ts` 的 `--el-color-primary` | blog-app 全仓 `grep` 该 CSS 变量：仅 `uno.config.ts` 引用，无定义 |
| `permission.ts:41` 恒真 | `userInfo` 初始值 `user_id: ""`（`stores/modules/user.ts:54-69`）与 `!== undefined` 比较直接推出 |
