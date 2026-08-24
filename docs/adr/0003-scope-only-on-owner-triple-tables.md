# @scope 只挂带归属三元组的表：basic 与 sys_user

数据范围守卫的过滤目标是归属三元组（owner_user_id / owner_dept_id / owner_user_group_id），库表中只有业务模板表 basic 与 sys_user 携带；sys_dept 的 owner_user_id 语义是"部门管理员"而非行归属，组织树、字典、菜单、日志、配置等是租户内公共基础设施（管理入口由功能权限控制，不做行裁剪）。因此仅这两张表挂 @scope（各三条 OR 守卫），其余 16 张租户表只靠 RLS 租户隔离；新业务表复制 basic 模式即可获得守卫。明确不追求"全部表按数据范围裁剪"。
