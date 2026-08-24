# 守卫函数单参设计：只收用户 ID，推导留在库内

守卫函数采用 `fn_accessible_user_ids(p_user_id int8) RETURNS TABLE(...)` 单参形态——角色到数据范围（data_scope 1-7）的推导在函数内部 join sys_user_role_mapping × sys_role 完成，而非插件 example 的 `(p_user_id, p_scopes int[])` 双参形态。理由：角色本来就在库里，推导留在数据旁边即单一事实源——撤销角色下一笔查询立即生效；复用方契约最小（AuthContext 的 UserID 一行注入 Scope）；List/Count/游标一致性由同一数据库状态自动保证。运行时"视角收窄"是 scopes 参数的唯一独特价值，改由归属列业务过滤实现（守卫 AND 业务过滤，只能收窄永不放大）。

## Considered Options

- **双参 `(p_user_id, p_scopes int[])` 应用侧推导**：每个复用方都要重写推导逻辑；session 缓存存在权限撤销延迟窗口；应用层误传 scopes（如 [7]）即放大可见边界。弃。
- **包装 basic-db-table 现有 fn_perm_***：数组返回与 IN 守卫类型不匹配，且其 NULL=不限 语义在 IN 下退化为全拒。弃。

## Consequences

- 守卫子查询内含角色 join（每查询两次小索引扫描，管理列表场景可忽略）。
- basic-db-table 的 fun.sql 保持原样；本项目在 rls.sql 自带行集形态守卫函数三件套：fn_accessible_user_ids / fn_accessible_dept_ids / fn_accessible_group_ids。
- 归属列保留 @dynamic: exact, in 业务过滤，作为视角收窄通道。

> 修订：守卫函数返回形态后来改为数组三态契约（NULL=全租户，插件 v0.1.2 in_any 守卫消费），见 [ADR-0005](0005-in-any-three-state-guard.md)；本文的单参决策不变。
