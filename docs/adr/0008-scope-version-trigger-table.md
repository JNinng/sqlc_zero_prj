# 范围版本：触发器维护 + 租户/用户双粒度

外部进程缓存可视范围/权限码结果是既定用法（批量接口即为远程优化而生），必须有缓存失效信号。事实：影响判定结果的表中 `sys_user_role_mapping`、`sys_role_id_scope`、`sys_role_menu` 均为**物理删除且无 updated_at**，多表 `max(updated_at)`/`count` 聚合对删除和等量替换（删一加一）视而不见，会造成外部缓存永久脏。决定：触发器维护版本表 `sys_perm_version(tenant_id, user_id, version)`，在影响判定结果的表（sys_user、sys_user_role_mapping、sys_role、sys_role_id_scope、sys_role_menu、sys_menu、部门及闭包变更）上挂 bump 触发器；**双粒度**：角色/菜单/组织侧变更 bump 租户级版本，用户自身行与角色映射变更只 bump 该用户的用户级版本；缓存有效性 = 两个版本都未变。契约：版本相等即可安全续用缓存，不等则重拉；版本只用于相等比较、不承诺跨表有序，是失效信号、不是变更日志。

## Considered Options

- **聚合查询法（count + max(updated_at) 兜底）**：零新增触发器，但对物理删除与等量替换有永久盲区；弃。
- **LISTEN/NOTIFY 实时推送**：要求长连接与推送基础设施，超出可复制模板的部署形态；弃。

## Consequences

- 与闭包表触发器同一哲学：失效逻辑在库内、应用零配合。
- 写路径每次变更多一次轻量 bump（可接受）；触发器清单与判定函数的输入表清单须同步维护，判定依赖表变更时两处都要改。
- 大租户一人变更只失效该用户缓存（用户级隔离），角色/菜单变更才租户级全量失效，无全域风暴。
