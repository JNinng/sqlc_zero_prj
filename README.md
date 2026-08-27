# sqlc_zero_prj — 可复制的数据权限体系

以 [basic-db-table](../../template/basic-db-table) 的多租户 RBAC 库表为基础，用
[sqlc](https://sqlc.dev) + 自定义插件 [sqlc_gen_dynamic](../sqlc_gen_dynamic)
生成带行级守卫的动态列表查询，形成的**可整仓复制**的数据权限起步模板：
schema/RLS/守卫函数/种子/演示一应俱全，业务项目复制后改业务表即可运行。

## 三层权限模型

三个正交维度，各归其位（详见 [ADR-0001](docs/adr/0001-dual-layer-permission.md)）：

| 层 | 维度 | 执行者 | 失效姿态 |
|---|---|---|---|
| PostgreSQL RLS | 租户隔离（绝对边界） | 21 张租户表策略，`tenant_id = current_setting('app.tenant_id')`，ENABLE + FORCE | 漏设变量 → 默认全拒 |
| `@scope` 守卫 | 数据范围（data_scope 1-7，多角色并集） | 生成代码 WHERE 头部注入守卫谓词 | 缺 Scope → fail-closed 报错 |
| 判定函数（写侧） | 操作权限（分配/归属转移/行操作） | `operate.sql` 布尔判定 + 同事务先检后写 | 判定 false → ErrDenied 回滚 |
| sys_menu 功能权限 | 功能入口（能用哪些操作） | 应用层（权限码），不做行过滤 | — |
| 查询判断函数（读侧） | 同上两轴的只读暴露 | `expose.sql` 三函数 + `perm/` 服务层，内外同源（[ADR-0007](docs/adr/0007-permission-query-interface-same-source.md)） | 拒绝 = false/空集，非错误 |

关键语义（速查）：

- **权限过滤函数只收一个用户 ID**：`fn_accessible_user_ids/dept_ids/group_ids(用户ID)`，该用户能看到什么由函数内部查角色算出，撤销角色下一次查询立刻生效（[ADR-0002](docs/adr/0002-single-param-guard-functions.md)）。返回 `NULL`=全租户不过滤（仅 data_scope=7）、`{}`=什么都看不到、数组=可见列表（[ADR-0005](docs/adr/0005-in-any-three-state-guard.md)）。
- **@scope 只挂在有归属字段的表上**：挂载清单以 `sqlcpg/schema.sql` 的表注释为准（模板内为 `basic` 与 `sys_user`）；其余表租户内所有人可见（[ADR-0003](docs/adr/0003-scope-only-on-owner-triple-tables.md)）。
- **没有归属的数据只有全租户角色能看到**：三个归属字段全空的数据，对其他档位不可见（[ADR-0005](docs/adr/0005-in-any-three-state-guard.md)）。
- **加过滤条件只会看得更少**：前端传 `ownerUserId=自己` 之类的条件叠加在权限过滤之上，不会放大可见范围。
- **写之前先判断**（[ADR-0006](docs/adr/0006-operate-permission-check.md)）：能看见就能操作；改归属两头校验（这条数据有权操作 + 新归属的人/部门/组可见）；判断和写入同一事务，不通过就报 `ErrDenied`（403）回滚。角色分配的 `sys_role_allowed_dept`/`scope_dept_id` 规则由 `fn_can_assign_role` 在库内执行。
- **权限查询接口内外同源**（[ADR-0007](docs/adr/0007-permission-query-interface-same-source.md)）：外部进程（不同进程、不同库，数据以归属字段引用本库 ID）经根级 `perm/` 服务层查询——单点/批量可见性判断（维度掩码 1 人/2 部门/4 组，OR 并集）、功能权限码、三维度可视范围（三态 `{All, IDs}`，全租户不展开全量）、用户字段投影、角色/权限码枚举、范围版本缓存失效（[ADR-0008](docs/adr/0008-scope-version-trigger-table.md)，触发器维护、租户/用户双粒度）。HTTP/gRPC 外壳由宿主自包。
- 术语表见 [CONTEXT.md](CONTEXT.md)。

## 目录结构

```
sqlcpg/                  生成目录（sqlc 工作区）
  README.md              SQL 对象参考：文件/函数/命名查询索引（改动须三处同步）
  sqlc.yaml              sqlc 配置：内置 go 生成器 + sqlc_gen_dynamic 插件并行
  schema.sql             表结构 + @dynamic/@scope DSL 注释（sqlc 输入）
  rls.sql                RLS 策略 + 守卫函数三件套 + test_u 授权（部署件；纳入 sqlc schema 列表以解析三件套签名）
  operate.sql            操作权限判定函数三件（写侧执行体；纳入 sqlc schema 列表以解析签名）
  expose.sql             权限查询接口：查询判断函数三件 + 范围版本表与触发器（读侧；纳入 sqlc schema 列表以解析签名）
  seed.sql               种子（基础数据 + data_scope 演示数据 + basic 归属矩阵）
  gen/                   生成代码（勿手改）
perm/                    权限查询接口服务层（接口本体，传输无关；宿主自包 HTTP/gRPC）
example/                 独立 Go module（replace => ../），消费方接入范式
  mod.go                 门面：AuthContext → RLS 会话注入 → Scope 注入 → List/Count
  cmd/demo/main.go       可运行验收：重建测试库 + 23 场景断言
docs/adr/                架构决策记录（ADR）
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
`schema.sql → rls.sql → operate.sql → expose.sql → seed.sql`，再以 **test_u 普通角色**连接跑全部验收场景：

- data_scope 1-7 逐档可见性（同一张 basic 表，不同角色视角结果断言）
- 多角色并集、加过滤条件只能看得更少
- fail-closed（未注入 Scope → `Kind=scope` 错误，绝不静默全量）
- RLS 层独立验证（漏设 `app.tenant_id` → 0 行，即使 Scope 已注入）
- 配了 @scope 的表（SysUser）与没配的表（SysDictData）对照
- 写入前判断（[13]-[17]）：越权分配被拒（目标不可见/目标部门不符合配置，
  拒绝即无写入）、部门命中角色配置放行、改归属两头校验（新归属人可见、
  旧行有权操作）、改归属成功（写后同事务读回确认）、批量分配多个角色
  （一次判断，任一不通过整批拒绝；已拥有的角色跳过）
- 权限查询接口（[18]-[23]，`perm/` 服务层）：单点判断与维度掩码选择
  （含无效掩码 fail-closed）、批量过滤只回可见子集、功能权限码判断与
  枚举、可视范围三态（All/数组/空数组）、用户字段投影（@hidden 挡住
  敏感列）、范围版本双粒度失效（一人变更不风暴全租户）

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
4. **写动作套判定模板**：复杂跨表规则（如角色分配）写具体判定函数
   `fn_can_xxx(p_operator, ...)`，通用行操作复用 `fn_can_operate_row`，
   归属转移复用 `fn_can_transfer_owner`（双向可达）；判定与写入同事务
   先检后写，false 返回 `ErrDenied`（HTTP 403）。判定函数的参数含义、
   算法与返回语义必须在函数前注释与 COMMENT ON FUNCTION 成文。
5. **门面抄 `example/mod.go`**：`AuthContext{TenantID, UserID}` +
   `Begin`（事务级 set_config）+ 资源 API（读：Parse 后注入 Scope 再
   List/Count；写：判定后写入，named queries 经 `Session.Q()` 实例调用）。
6. **运行连接三条纪律**：普通数据库角色（勿用超级用户，会绕过 RLS）；
   每事务 `set_config('app.tenant_id', ..., true)`；Scope 只从服务端认证
   上下文注入，永不受前端请求影响。
7. INSERT 业务行时由应用层强制填充归属三元组至少一项（无归属行仅
   data_scope=7 可见可操作，ADR-0005）。

## 边界与后续

- 查询侧完备（动态 List/Count + 权限 + `perm/` 权限查询接口）；写侧以
  **检测机制模板**形态交付（角色分配 + 归属转移两条链路端到端，其余表
  的写侧 named queries 与通用修改/软删流程仍为后续工作）。
- `sys_dept` 等其余租户表不做数据范围裁剪（组织树/字典/日志为租户内
  公共数据，管理入口由功能权限控制）；需要时按 basic 模式自行加守卫。
- 权限查询接口已交付 8 个方法（判断/范围/主数据/枚举/版本五类）；
  明确不在本期：反向批量（这批操作者里谁能看见 Y）、用户状态判断、
  部门/组主数据投喂、可视范围紧凑表示（部门子树 ⊕ 残余用户）。
  HTTP/gRPC 适配器属宿主系统，不在本仓交付范围。
