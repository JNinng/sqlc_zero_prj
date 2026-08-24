# sqlc_zero_prj — 可复制的数据权限体系

以 [basic-db-table](../template/basic-db-table) 的多租户 RBAC 库表为基础，用
[sqlc](https://sqlc.dev) + 自定义插件 [sqlc_gen_dynamic](../Go/sqlc_gen_dynamic)
生成带行级守卫的动态列表查询，形成的**可整仓复制**的数据权限起步模板：
schema/RLS/守卫函数/种子/演示一应俱全，业务项目复制后改业务表即可运行。

## 三层权限模型

三个正交维度，各归其位（详见 [ADR-0001](docs/adr/0001-dual-layer-permission.md)）：

| 层 | 维度 | 执行者 | 失效姿态 |
|---|---|---|---|
| PostgreSQL RLS | 租户隔离（绝对边界） | 21 张租户表策略，`tenant_id = current_setting('app.tenant_id')`，ENABLE + FORCE | 漏设变量 → 默认全拒 |
| `@scope` 守卫 | 数据范围（data_scope 1-7，多角色并集） | 生成代码 WHERE 头部注入守卫谓词 | 缺 Scope → fail-closed 报错 |
| sys_menu 功能权限 | 功能入口（能用哪些操作） | 应用层（权限码），不做行过滤 | — |

关键语义（速查）：

- **守卫函数单参 + 数组三态**：`fn_accessible_user_ids/dept_ids/group_ids(p_user_id)`，角色→数据范围的推导在库内完成，撤销角色下一笔查询即时生效（[ADR-0002](docs/adr/0002-single-param-guard-functions.md)）；返回 `NULL`=全租户不限（仅 data_scope=7 分支）、`{}`=拒绝一切、非空数组=多角色并集，由插件 v0.1.2 的 `in_any` 守卫消费（[ADR-0005](docs/adr/0005-in-any-three-state-guard.md)）。
- **@scope 只挂带归属三元组的表**：目前为 `basic` 与 `sys_user`（各三条 OR 守卫）；其余表租户内公共（[ADR-0003](docs/adr/0003-scope-only-on-owner-triple-tables.md)）。
- **无归属行仅全租户可见**：owner 三列全 NULL 的行经守卫 NULL 放行对 data_scope=7 可见，对其余档位不可见（[ADR-0005](docs/adr/0005-in-any-three-state-guard.md)）。
- **视角收窄**：守卫与业务过滤 AND 组合——前端传 `ownerUserId=自己` 等条件只能收窄、永不放大。
- 术语表见 [CONTEXT.md](CONTEXT.md)。

## 目录结构

```
sqlcpg/                  生成目录（sqlc 工作区）
  sqlc.yaml              sqlc 配置：内置 go 生成器 + sqlc_gen_dynamic 插件并行
  schema.sql             表结构 + @dynamic/@scope DSL 注释（sqlc 输入）
  rls.sql                RLS 策略 + 守卫函数三件套 + test_u 授权（部署件，非 sqlc 输入）
  seed.sql               种子（基础数据 + data_scope 演示数据 + basic 归属矩阵）
  gen/                   生成代码（勿手改）
example/                 独立 Go module（replace => ../），消费方接入范式
  mod.go                 门面：AuthContext → RLS 会话注入 → Scope 注入 → List/Count
  cmd/demo/main.go       可运行验收：重建测试库 + 12 场景断言
docs/adr/                架构决策记录 0001-0004
CONTEXT.md               领域术语表
```

## 快速开始

先决条件：PostgreSQL 15+（按 basic-db-table 基线建议 18）、Go 1.26+；
本机 PostgreSQL 可达（默认 `postgres://postgresql:root@localhost:5432/postgres`）。

```bash
cd example
go run ./cmd/demo
```

演示自动重建测试库 `sqlc_zero_prj_demo`（DROP + CREATE），按序执行
`schema.sql → rls.sql → seed.sql`，再以 **test_u 普通角色**连接跑 12 个场景：

- data_scope 1-7 逐档可见性（同一张 basic 表，不同角色视角结果断言）
- 多角色并集、视角收窄（业务过滤叠加守卫）
- fail-closed（未注入 Scope → `Kind=scope` 错误，绝不静默全量）
- RLS 层独立验证（漏设 `app.tenant_id` → 0 行，即使 Scope 已注入）
- 守卫资源（SysUser）与无守卫资源（SysDictData）对照

连接覆盖：`ZERO_DEMO_ADMIN_DSN`（管理库）、`ZERO_DEMO_TEST_DSN`（test_u 连测试库）。
任一断言失败即非零退出，可直接用作 CI 验收。

## 再生成

改 `sqlcpg/schema.sql`（表结构或 DSL 注释）后：

```bash
cd sqlcpg && sqlc generate
```

插件为 WASM 形态（`sqlc_gen_dynamic` v0.1.2，见 sqlc.yaml），按表注释 DSL
生成 `*_dynamic_gen.go`；`@scope ... in_any` 声明会生成 `XxxScope` 结构体、
fail-closed 校验与三态守卫谓词 `(fn IS NULL OR col = ANY(fn))`。
守卫函数在库内的存在性由 `rls.sql` 部署保证，sqlc 不校验。

## 复制到新业务项目

1. **带走 `sqlcpg/`**：复制目录，改 go.mod 模块名与 `sqlc.yaml` 里的
   `runtime_import` 不变（dynq 运行时直接引用 `github.com/jninng/sqlc_gen_dynamic`）。
2. **业务表抄 `basic` 模式**：建表带 `tenant_id` + 审计列 + 归属三元组，
   表注释挂三条守卫：
   ```sql
   COMMENT ON TABLE my_biz IS '业务表 [@scope: owner_user_id in_any fn_accessible_user_ids(user_id:int) owner_dept_id in_any fn_accessible_dept_ids(user_id:int) owner_user_group_id in_any fn_accessible_group_ids(user_id:int) @default_sort: created_at DESC @pk: id @page: 20/200]';
   ```
   列注释按需声明 `@dynamic/@sortable/@selectable/@hidden`；归属列保留
   `@dynamic: exact, in` 作为收窄通道。
3. **新表补一条 RLS 策略**（照抄 rls.sql 任意一条 + ENABLE/FORCE）。
4. **门面抄 `example/mod.go`**：`AuthContext{TenantID, UserID}` +
   `Begin`（事务级 set_config）+ 资源 API（Parse 后注入 Scope 再 List/Count）。
5. **运行连接三条纪律**：普通数据库角色（勿用超级用户，会绕过 RLS）；
   每事务 `set_config('app.tenant_id', ..., true)`；Scope 只从服务端认证
   上下文注入，永不受前端请求影响。
6. INSERT 业务行时由应用层强制填充归属三元组至少一项（ADR-0004）。

## 边界与后续

- 本仓库只覆盖**查询侧**（动态 List/Count + 权限）；写侧（INSERT/UPDATE/
  软删的 named queries 与审计字段填充策略）为后续工作。
- `sys_dept` 等其余 16 张租户表不做数据范围裁剪（组织树/字典/日志为租户内
  公共数据，管理入口由功能权限控制）；需要时按 basic 模式自行加守卫。
