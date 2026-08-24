-- 判定与写链路的 named queries：判定函数（operate.sql）与写入语句
-- 全部走 sqlc 类型层；归属参数用 sqlc.narg（可空 *int64），NULL 语义
-- 直达判定函数（NULL = 无该维归属），不经过零值转换。
-- 写入的租户事实取 current_setting('app.tenant_id')（与 RLS WITH CHECK
-- 同源），操作者事实（created_by/updated_by）由门面从 AuthContext 传入。

-- name: GetUser :one
SELECT * FROM sys_user WHERE id = $1;

-- name: CanAssignRole :one
SELECT public.fn_can_assign_role(sqlc.arg('operator'), sqlc.arg('role'), sqlc.arg('target')) AS ok;

-- name: CanTransferOwner :one
SELECT public.fn_can_transfer_owner(sqlc.arg('operator'),
                                    sqlc.narg('old_user'), sqlc.narg('old_dept'), sqlc.narg('old_group'),
                                    sqlc.narg('new_user'), sqlc.narg('new_dept'), sqlc.narg('new_group')) AS ok;

-- name: GetBasicForUpdate :one
SELECT *
FROM public.basic
WHERE id = sqlc.arg('id')
FOR UPDATE;

-- name: AssignUserRole :exec
INSERT INTO public.sys_user_role_mapping (user_id, role_id, tenant_id, created_by)
VALUES (sqlc.arg('user_id'), sqlc.arg('role_id'), current_setting('app.tenant_id'), sqlc.arg('created_by'))
ON CONFLICT (user_id, role_id) DO NOTHING;

-- name: UpdateBasicOwner :exec
UPDATE public.basic
SET owner_user_id       = sqlc.narg('owner_user'),
    owner_dept_id       = sqlc.narg('owner_dept'),
    owner_user_group_id = sqlc.narg('owner_group'),
    updated_by          = sqlc.arg('updated_by')
WHERE id = sqlc.arg('id');

-- name: HasUserRole :one
SELECT EXISTS (SELECT 1
               FROM public.sys_user_role_mapping
               WHERE user_id = sqlc.arg('user_id')
                 AND role_id = sqlc.arg('role_id')) AS has;
