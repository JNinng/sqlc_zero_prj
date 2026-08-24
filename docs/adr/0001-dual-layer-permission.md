# 双层权限执行：RLS 租户隔离 + @scope 数据范围

行级权限有两个正交维度需要执行：跨租户的绝对隔离（安全边界）与租户内按角色数据范围的行过滤（业务边界）。决定分两层执行：租户隔离由 PostgreSQL RLS 执行（每张租户表一条 `tenant_id = current_setting('app.tenant_id')` 策略，ENABLE + FORCE，未设置默认全拒），数据范围由 sqlc_gen_dynamic 的 @scope 守卫在生成代码中执行（WHERE 头部注入守卫谓词，Scope 缺失即 fail-closed）。功能入口则由 sys_menu 功能权限控制，不参与行过滤。

## Considered Options

- **仅 @scope（租户守卫也走生成代码）**：少一层兜底；会话变量与数据库角色体系（FORCE RLS、GRANT SET ON PARAMETER）全部闲置，弃。
- **仅 RLS（data_scope 写进 policy）**：policy 复杂化，且失去生成代码的 fail-closed 与 List/Count 同源一致性，弃。

## Consequences

- 防御纵深：任一层配置失误由另一层兜底（守卫漏配不跨租户；会话变量漏配仍受守卫限制）。
- data_scope 语义变更只需改守卫函数，RLS 策略不动。
- 演示/运行需非超级用户连接（超级用户绕过 RLS，FORCE 只约束表 owner）——example 以 test_u 演示。
