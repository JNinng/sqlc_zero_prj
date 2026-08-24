# 操作权限：判定函数 + 同事务先检后写

写侧此前对数据范围零约束（RLS WITH CHECK 只管租户），角色分配规则（sys_role_allowed_dept/scope_dept_id）虽有成文注释但"仅应用层 enforce"、从未实现。决定：操作权限由**判定函数**执行——`fn_can_assign_role`（分配成文规则的执行体）、`fn_can_operate_row`（通用行判定，读写同权）、`fn_can_transfer_owner`（归属转移双向可达：旧行可达 + 新归属目标可达，堵"转给看不见的人"的外流旁路）——判定与写入**同事务先检后写**，false 即 ErrDenied 回滚。判定与守卫共享同一套 data_scope 推导（撤销角色读写同时即时生效）；RLS 维持只管租户（ADR-0001 分层不变）。判定函数参数多、语义关键：参数含义/算法/返回语义在函数前注释与 COMMENT ON FUNCTION 双处成文，改动须同步。

## Considered Options

- **判定写进 RLS policy**：角色分配是跨表规则，行级 policy 无法表达；弃。
- **纯应用层判定**：推导逻辑散落到每个复用方，违背可复制初衷；弃。

## Consequences

- 判定函数经 named queries 类型化调用（queries.sql 包装 `SELECT fn_...`，归属参数 sqlc.narg 传 NULL 语义）；operate.sql 纳入 sqlc schema 输入列表以解析函数签名。
- 写入语句：tenant_id 取 current_setting（与 RLS WITH CHECK 同源）、操作者取 AuthContext、updated_at 交 touch 触发器；named queries 均为 *Queries 方法（New(db) 实例化调用），与动态查询顶层函数是两种生成风格。
- role_type=1（系统预置）不加"仅租户管理员可分配"隐性特例，规则统一；业务方需要防提权时在判定函数加分支（读写同权同理留收窄口子）。
- "角色列表仅对命中部门管理员可见"属读侧呈现策略，不在判定范围。
