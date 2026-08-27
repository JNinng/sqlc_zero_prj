# sqlcpg — SQL 对象参考

数据权限体系的 SQL 载体。五个 `*.sql` 按顺序执行；本文件是这些文件里
**函数和命名查询的索引**：每个对象的签名、用途和返回值约定。

修改任何函数或查询时，同步更新三处：SQL 里的注释、`COMMENT ON
FUNCTION`、本文件的索引表。

## 文件总览（按执行顺序）

| # | 文件 | 干什么 | sqlc 输入 | 内容 |
|---|---|---|---|---|
| 1 | schema.sql | 建表，表注释里带 @dynamic/@scope 指令；部门闭包触发器 | 是 | 22 张表、1 个触发器函数 |
| 2 | rls.sql | 租户隔离 RLS 策略；三个权限过滤函数；updated_at 触发器；test_u 授权 | 是（只读函数签名） | 21 条策略、4 个函数 |
| 3 | operate.sql | 写数据前的权限判断函数 | 是（只读函数签名） | 4 个判断函数 |
| 4 | expose.sql | 权限查询接口：面向外部进程的只读判定函数；范围版本表 + bump 触发器 | 是（只读函数签名） | 3 个查询判断函数、1 张版本表、3 个触发器函数 |
| 5 | seed.sql | 种子数据（含权限演示数据） | 否 | 租户/部门/角色/用户/用户组/字典 + basic 演示数据 |

- sqlc.yaml 的 schema 列表是 `[schema.sql, rls.sql, operate.sql,
  expose.sql]`：加 rls/operate/expose 是为了让 queries.sql 里的查询
  能调用这些文件里的函数（GetScope 调三件套、判断类调 fn_can_* /
  fn_check_visible）；sqlc 只看签名，函数体是否存在于库里由执行
  顺序保证。
- 执行顺序：**schema → rls → operate → expose → seed**（example/
  cmd/demo 的 setup 就是这个顺序；seed 里有别的租户的数据，要用
  超级用户执行）。expose.sql 必须在 seed 之前：种子数据的角色映射
  写入要触发版本表 bump。

## 函数索引

属性说明：S=STABLE（同一事务内重复调用结果一致）；默认 SECURITY
INVOKER（以调用者身份执行，受 RLS 约束）。除触发器函数外，调用前
会话必须已设置 `app.tenant_id`。

### 权限过滤函数（rls.sql，查询用）

列表查询自动把返回值拼进 WHERE（`owner_xx = ANY(fn(...))`）。
三个函数返回值约定相同：

| 返回值 | 含义 |
|---|---|
| NULL | 有全租户角色（data_scope=7），不过滤 |
| '{}' | 用户无效或没有有效角色，什么都看不到 |
| 数组 | 能看到的 ID 列表，多个角色取并集 |

| 函数 | 签名 | 属性 | 返回什么 |
|---|---|---|---|
| fn_accessible_user_ids | (用户ID) → int8[] | S | 能看到哪些用户 |
| fn_accessible_dept_ids | (用户ID) → int8[] | S | 能看到哪些部门（"仅本人"角色也算上自己所在部门，保证自己的数据不被过滤掉） |
| fn_accessible_group_ids | (用户ID) → int8[] | S | 能看到哪些用户组（只有"指定用户组"和"全租户"两类角色有结果） |

### 写前判断函数（operate.sql）

写数据前先调用，返回 true 才执行写入（同一个事务，false 就报错回滚）。

| 函数 | 签名 | 属性 | 判断什么 |
|---|---|---|---|
| fn_can_assign_role | (操作者, 角色, 目标用户) → boolean | S | 能否把角色分配给用户。角色配了分发部门时：目标部门须在配置内，且操作者部门命中配置、或能看见目标用户；没配时按 scope_dept_id 子树 + 能看见目标用户判断 |
| fn_can_assign_roles | (操作者, 角色数组, 目标用户) → (role_id, ok) 行集 | S | 上面那条的批量版：对数组里每个角色独立判断，逐个返回结论；全部通过才批量写入 |
| fn_can_operate_row | (用户, 归属人, 归属部门, 归属组) → boolean | S | 能否修改/删除一条数据。能看见就能操作：有全租户角色直接通过；否则任一归属命中可见范围即通过；三个归属全空的数据只有全租户能操作 |
| fn_can_transfer_owner | (用户, 旧归属×3, 新归属×3) → boolean | S | 能否修改数据的归属。两头都要过：这条数据本身有权操作，且新归属的人/部门/组在可见范围内（防止把数据转给自己看不见的人） |

### 查询判断函数（expose.sql，外部查询用）

只读判定，不与写事务绑定；与上面两个家族共用同一套 data_scope
推导（内外同源，ADR-0007）。供根级 `perm/` 服务层调用（HTTP/gRPC
由宿主自包）。拒绝返回 false/空集，不是错误。

| 函数 | 签名 | 属性 | 判断什么 |
|---|---|---|---|
| fn_check_visible | (用户, 维度掩码, 归属人, 归属部门, 归属组) → boolean | S | 能否看见/操作一条数据（读写同权）。维度掩码：1 人、2 部门、4 组，按位组合 OR 并集；fn_can_operate_row 等价于掩码 7。掩码无效（0/超界）fail-closed |
| fn_filter_visible_rows | (用户, 维度掩码, 归属人数组, 归属部门数组, 归属组数组) → 归属三元组行集 | S | 上面那条的批量版：三个数组按下标对齐，只返回可见子集（保持传入顺序）。数组元素可为 NULL（无该归属） |
| fn_has_permission | (用户, 权限码) → boolean | S | 功能权限轴：用户的有效角色是否关联了携带该权限码的有效菜单（角色→菜单→权限码，与数据范围正交） |

### 触发器函数

| 函数 | 所在文件 | 用途 |
|---|---|---|
| fn_maintain_dept_closure | schema.sql | 部门增删改时自动维护闭包表：校验父部门、防环；软删当删除处理、恢复当新增处理；还有子部门时不允许删 |
| fn_touch_updated_at | rls.sql | UPDATE 时如果应用层没改 updated_at，就自动刷新它（批量挂在所有有 updated_at 列的表上） |
| fn_bump_perm_version | expose.sql | 范围版本自增（ADR-0008）：租户级行（user_id=0）或用户级行，不存在从 1 起建 |
| fn_touch_perm_version_user_row | expose.sql | sys_user 行变化 → bump 该用户版本（挂在 status/软删/归属三元组列上） |
| fn_touch_perm_version_mapping | expose.sql | sys_user_role_mapping 增删改 → bump 该用户版本 |
| fn_touch_perm_version_tenant | expose.sql | 角色/菜单/组织侧表增删改 → bump 租户级行（挂在 sys_role、sys_role_id_scope、sys_role_menu、sys_menu、sys_dept 上） |

挂载清单 = 判定函数的输入表清单，两处必须同步改。

## 命名查询索引（queries.sql）

| 查询 | 类型 | 参数 → 返回 | 干什么 |
|---|---|---|---|
| CanAssignRole | :one | 操作者/角色/目标 → bool | 分配前的权限判断 |
| CanAssignRoles | :many | 操作者/角色列表/目标 → (role_id, ok) 行 | 批量分配前的权限判断（逐个角色） |
| CanTransferOwner | :one | 操作者 + 旧/新归属（可空）→ bool | 改归属前的权限判断 |
| GetBasicForUpdate | :one | id → Basic | 锁行并读出当前归属（FOR UPDATE） |
| AssignUserRole | :exec | 用户/角色/操作者 | 写入一条角色映射，租户自动取会话值，重复分配不报错 |
| AssignUserRoles | :execrows | 用户/角色列表/操作者 → 新增条数 | 批量写入角色映射，已拥有的跳过 |
| UpdateBasicOwner | :exec | 新归属（可空）+ 操作者 + id | 修改归属，updated_at 自动刷新 |
| HasUserRole | :one | 用户/角色 → bool | 确认分配结果是否落库 |
| CheckVisible | :one | 操作者/维度掩码/归属三元组（可空）→ bool | 权限查询：单点可见性判断（fn_check_visible） |
| HasPermission | :one | 操作者/权限码 → bool | 权限查询：功能权限码判断（fn_has_permission） |
| GetScope | :one | 操作者 → 三个 int8[] 列（可 NULL） | 权限查询：三维度可见集合一次取回（三件套同返；NULL=全租户由 perm 层翻成 All） |
| GetUserRoles | :many | 用户 → SysRole 行 | 权限查询：枚举有效角色 |
| GetPermissionCodes | :many | 用户 → 权限码列表（去重排序） | 权限查询：枚举权限码（菜单渲染/网关缓存） |
| GetScopeVersion | :one | 用户 → (租户版本, 用户版本) | 权限查询：范围版本，缓存失效信号（ADR-0008；行不存在补 0） |

批量过滤 fn_filter_visible_rows 没有对应命名查询：sqlc 解析不了
表函数的返回列，perm 服务层直接以参数化 SQL 调用该函数。

注意：命名查询生成的是 `*Queries` 上的**方法**（`gen.New(db)` 实例化后
调用）；动态查询生成的是顶层函数（ParseXxx/ListXxx，db 作参数显式传）。
两种风格不要混淆。

## RLS 策略（rls.sql）

21 张租户表用同一条规则：`tenant_id = current_setting('app.tenant_id')`，
读和写都检查，表主也不豁免（FORCE）。会话没设置 app.tenant_id 时
什么都读不到、写不进。sys_tenant 额外允许命中自身 id（子租户挂在
父租户名下时还能读写自己的行）。sys_config 是全局配置、没有租户列，
不设 RLS。
