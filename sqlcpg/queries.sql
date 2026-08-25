-- 命名查询：读、写、权限判断都走 sqlc 类型层。
-- 归属类参数用 sqlc.narg（生成 *int64 可空指针），NULL 原样传给
-- 判断函数，表示"没有这个归属"，不做零值转换。
-- 每条查询上方的注释会被 sqlc 带进生成的 Go 代码（godoc），
-- 修改时记得同步。

-- 按主键查一个用户（RLS 生效：别的租户里查不到）
-- name: GetUser :one
SELECT * FROM sys_user WHERE id = $1;

-- 判断当前用户能否把某个角色分配给某个用户（规则见 fn_can_assign_role）
-- name: CanAssignRole :one
SELECT public.fn_can_assign_role(sqlc.arg('operator'), sqlc.arg('role'), sqlc.arg('target')) AS ok;

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
