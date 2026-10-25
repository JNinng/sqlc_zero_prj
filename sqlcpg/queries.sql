-- 命名查询：读、写、权限判断都走 sqlc 类型层。
-- 归属类参数用 sqlc.narg（生成 *int64 可空指针），NULL 原样传给
-- 判断函数，表示"没有这个归属"，不做零值转换。
-- 每条查询上方的注释会被 sqlc 带进生成的 Go 代码（godoc），
-- 修改时记得同步。

-- 判断当前用户能否把某个角色分配给某个用户（规则见 fn_can_assign_role）
-- name: CanAssignRole :one
SELECT public.fn_can_assign_role(sqlc.arg('operator'), sqlc.arg('role'), sqlc.arg('target')) AS ok;

-- 批量版：一次判断多个角色，每个角色一行（role_id, ok），
-- 全部通过才允许批量写入（规则同 fn_can_assign_role；
-- 与 fn_can_assign_roles 函数体一致，直接 SQL 调用时用那个函数）
-- name: CanAssignRoles :many
SELECT r::int8 AS role_id,
       public.fn_can_assign_role(sqlc.arg('operator'), r, sqlc.arg('target')) AS ok
FROM unnest(sqlc.arg('role_ids')::int8[]) AS r;

-- 判断能否把某条数据的归属改成新归属：两头都要过——这条数据本身
-- 有权操作，新归属的人/部门/组也在可见范围内（见 fn_can_transfer_owner）
-- name: CanTransferOwner :one
SELECT public.fn_can_transfer_owner(sqlc.arg('operator'),
                                    sqlc.narg('old_user'), sqlc.narg('old_dept'), sqlc.narg('old_group'),
                                    sqlc.narg('new_user'), sqlc.narg('new_dept'), sqlc.narg('new_group')) AS ok;

-- 按 id 锁定并读取一行 basic（FOR UPDATE）：改归属前先拿到它
-- 现在的归属值，防止并发修改后按旧值判断
-- name: GetBasicForUpdate :one
SELECT *
FROM public.basic
WHERE id = sqlc.arg('id')
FOR UPDATE;

-- 写入用户-角色映射（判断通过后调用）。租户自动取当前会话的
-- app.tenant_id；重复分配不报错、不重写
-- name: AssignUserRole :exec
INSERT INTO public.sys_user_role_mapping (user_id, role_id, tenant_id, created_by)
VALUES (sqlc.arg('user_id'), sqlc.arg('role_id'), current_setting('app.tenant_id'), sqlc.arg('created_by'))
ON CONFLICT (user_id, role_id) DO NOTHING;

-- 批量写入用户-角色映射（CanAssignRoles 全部通过后调用），
-- 返回实际新增的行数（已拥有的角色跳过、不报错）
-- name: AssignUserRoles :execrows
INSERT INTO public.sys_user_role_mapping (user_id, role_id, tenant_id, created_by)
SELECT sqlc.arg('user_id'), r, current_setting('app.tenant_id'), sqlc.arg('created_by')
FROM unnest(sqlc.arg('role_ids')::int8[]) AS r
ON CONFLICT (user_id, role_id) DO NOTHING;

-- 修改一行 basic 的归属（判断通过后调用）。归属参数传 NULL 表示
-- 清掉该归属；updated_at 由触发器自动刷新，不用手动设置
-- name: UpdateBasicOwner :exec
UPDATE public.basic
SET owner_user_id       = sqlc.narg('owner_user'),
    owner_dept_id       = sqlc.narg('owner_dept'),
    owner_user_group_id = sqlc.narg('owner_group'),
    updated_by          = sqlc.arg('updated_by')
WHERE id = sqlc.arg('id');

-- 查某个用户是否已拥有某个角色（分配后的结果确认）
-- name: HasUserRole :one
SELECT EXISTS (SELECT 1
               FROM public.sys_user_role_mapping
               WHERE user_id = sqlc.arg('user_id')
                 AND role_id = sqlc.arg('role_id')) AS has;

-- ============================================================
-- 权限查询接口（expose.sql 的函数 + 现有三件套），供 perm/ 服务层
-- 调用：单点判断、批量过滤、功能权限码、可视范围、角色/权限码
-- 枚举、范围版本。全部只读；拒绝以 false/空集表达，不是错误。
-- ============================================================

-- 按指定维度判断一条归属是否可见/可操作（读写同权）。
-- dims 用 perm.Dims 位组合：1 归属人、2 归属部门、4 归属用户组。
-- 归属参数传 NULL 表示"没有这个归属"（规则见 fn_check_visible）
-- name: CheckVisible :one
SELECT public.fn_check_visible(sqlc.arg('operator'), sqlc.arg('dims'),
                               sqlc.narg('owner_user'), sqlc.narg('owner_dept'), sqlc.narg('owner_group')) AS ok;

-- 判断用户是否持有某功能权限码（角色→菜单→权限码，与数据范围正交）
-- name: HasPermission :one
SELECT public.fn_has_permission(sqlc.arg('operator'), sqlc.arg('code')) AS ok;

-- 一次取回三个维度的可见集合（三件套一条 SQL 同返，省往返）。
-- 三态契约：列 NULL = 全租户不过滤（perm 层翻成 All=true），
-- 空数组 = 什么都看不见，数组 = 可见集合并集
-- name: GetScope :one
SELECT public.fn_accessible_user_ids(sqlc.arg('operator'))::int8[] AS user_ids,
       public.fn_accessible_dept_ids(sqlc.arg('operator'))::int8[] AS dept_ids,
       public.fn_accessible_group_ids(sqlc.arg('operator'))::int8[] AS group_ids;

-- 枚举有效用户的全部有效角色（展示/审计/外部缓存角色变更）。
-- 用户无效（不存在/禁用/删除）时返回空集
-- name: GetUserRoles :many
SELECT r.*
FROM public.sys_role r
         JOIN public.sys_user_role_mapping m ON m.role_id = r.id
         JOIN public.sys_user u ON u.id = m.user_id
WHERE m.user_id = sqlc.arg('user_id')
  AND u.status = 1
  AND u.deleted_at IS NULL
  AND r.status = 1
  AND r.deleted_at IS NULL
ORDER BY r.id;

-- 枚举有效用户的全部权限码（去重；前端菜单渲染、网关/远程系统缓存）。
-- 用户无效（不存在/禁用/删除）时返回空集
-- name: GetPermissionCodes :many
SELECT DISTINCT mu.permission_code
FROM public.sys_user u
         JOIN public.sys_user_role_mapping m ON m.user_id = u.id
         JOIN public.sys_role r ON r.id = m.role_id
    AND r.status = 1 AND r.deleted_at IS NULL
         JOIN public.sys_role_menu rm ON rm.role_id = r.id
         JOIN public.sys_menu mu ON mu.id = rm.menu_id
    AND mu.status = 1 AND mu.deleted_at IS NULL
WHERE u.id = sqlc.arg('user_id')
  AND u.status = 1
  AND u.deleted_at IS NULL
ORDER BY mu.permission_code;

-- 取范围版本（缓存失效信号，ADR-0008）：租户级 + 用户级一次取回，
-- 缓存有效性 = 两个版本都未变。行不存在时返回 0；RLS 已限本租户
-- name: GetScopeVersion :one
SELECT COALESCE((SELECT v.version
                 FROM public.sys_perm_version v
                 WHERE v.user_id = 0), 0)::int8 AS tenant_version,
       COALESCE((SELECT v.version
                 FROM public.sys_perm_version v
                 WHERE v.user_id = sqlc.arg('user_id')), 0)::int8 AS user_version;
