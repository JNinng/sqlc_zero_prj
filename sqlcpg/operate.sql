-- ============================================================
-- operate.sql — 写数据前的权限判断函数
--
-- 在 schema.sql、rls.sql 之后，seed.sql 之前执行。
-- 本文件同时列在 sqlc.yaml 的 schema 里：queries.sql 的命名查询要
-- 调用这些函数，sqlc 需要读到函数签名（sqlc 只看签名，不管函数体）。
--
-- 解决什么问题：
--   查询列表时 @scope 会自动过滤（见 rls.sql）；但写入是单条语句，
--   没有自动过滤的时机，所以写入前要显式判断一次。约定：先判断、
--   再写入，两步放在同一个事务里，判断不通过就直接报错回滚，
--   不产生任何写入（example/mod.go 有完整用法）。
--
-- 三个函数：
--   fn_can_assign_role     能否把某个角色分配给某个用户
--   fn_can_operate_row     能否修改/删除某条数据（按数据的归属判断）
--   fn_can_transfer_owner  能否把某条数据的归属改给别人
--
-- 注释约定：每个函数按「参数 → 判断逻辑 → 返回值」三段写；
-- 修改函数时，同步更新这段注释和 sqlcpg/README.md 里的索引。
-- ============================================================


-- ------------------------------------------------------------
-- fn_can_assign_role：当前用户能否把某个角色分配给另一个用户
--
-- 参数：
--   p_operator_id     发起分配的用户
--   p_role_id         要分配的角色
--   p_target_user_id  被分配的用户
--
-- 判断逻辑（同时满足才返回 true）：
--   1. 操作者、角色、目标用户都存在且有效（启用、未删除）。
--      RLS 已把查询限制在当前租户内，跨租户的对象等同于不存在。
--   2. 目标用户能接这个角色（看角色有没有配置分发部门）：
--      a. 角色在 sys_role_allowed_dept 里配了部门：目标用户所在部门
--         必须在这些部门之中；
--      b. 角色没配：角色的 scope_dept_id 为空即可；不为空时，目标
--         用户所在部门必须在 scope_dept_id 的部门子树内。
--   3. 操作者有资格分配，满足其一即可：
--      a. 操作者所在部门在角色的分发映射里（配了映射的角色按这条
--         规则走，不要求能看见目标用户）；
--      b. 目标用户在操作者能看到的用户范围内（data_scope 覆盖目标；
--         有全租户角色的人能看见所有人，自然全部通过）。
--
-- 返回：true = 允许分配，可以写入映射表；false = 拒绝，调用方报错
--       返回，不写入。
-- 补充：role_type=1（系统预置角色）没有特殊规则，同样按上面判断；
--       需要限制时在函数里加分支即可。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_can_assign_role(p_operator_id int8, p_role_id int8, p_target_user_id int8)
    RETURNS boolean
    STABLE
    LANGUAGE sql
AS $$
WITH operator AS (
    SELECT u.id, u.owner_dept_id
    FROM public.sys_user u
    WHERE u.id = p_operator_id
      AND u.status = 1
      AND u.deleted_at IS NULL
),
target AS (
    SELECT u.id, u.owner_dept_id
    FROM public.sys_user u
    WHERE u.id = p_target_user_id
      AND u.status = 1
      AND u.deleted_at IS NULL
),
role AS (
    SELECT r.id, r.scope_dept_id
    FROM public.sys_role r
    WHERE r.id = p_role_id
      AND r.status = 1
      AND r.deleted_at IS NULL
),
allowed AS (
    -- 角色配置的分发部门（sys_role_allowed_dept）
    SELECT a.dept_id
    FROM public.sys_role_allowed_dept a
    WHERE a.role_id = p_role_id
      AND a.status = 1
      AND a.deleted_at IS NULL
),
subtree AS (
    -- scope_dept_id 的部门子树（闭包表含自身）
    SELECT c.descendant_id AS dept_id
    FROM role r
             JOIN public.sys_dept_closure c ON c.ancestor_id = r.scope_dept_id
    WHERE r.scope_dept_id IS NOT NULL
)
SELECT EXISTS (SELECT 1 FROM operator)
   AND EXISTS (SELECT 1 FROM role)
   AND EXISTS (SELECT 1 FROM target)
   AND EXISTS (
    SELECT 1
    FROM target t
    WHERE CASE
              -- 角色配了分发映射的情况
              WHEN EXISTS (SELECT 1 FROM allowed) THEN
                      t.owner_dept_id IN (SELECT dept_id FROM allowed)
                      AND (
                          -- 操作者所在部门命中映射：直接有资格，不要求能看见目标
                          EXISTS (SELECT 1
                                  FROM operator o
                                  WHERE o.owner_dept_id IN (SELECT dept_id FROM allowed))
                          -- 或者：操作者能看见目标用户（全租户角色能看见所有人）
                          OR public.fn_accessible_user_ids(p_operator_id) IS NULL
                          OR t.id = ANY (public.fn_accessible_user_ids(p_operator_id))
                      )
              -- 角色没配映射的情况
              ELSE (
                      NOT EXISTS (SELECT 1 FROM role WHERE scope_dept_id IS NOT NULL)
                      OR t.owner_dept_id IN (SELECT dept_id FROM subtree)
                  )
                  AND (
                      public.fn_accessible_user_ids(p_operator_id) IS NULL
                      OR t.id = ANY (public.fn_accessible_user_ids(p_operator_id))
                  )
          END
)
$$;

COMMENT ON FUNCTION public.fn_can_assign_role(int8, int8, int8) IS '写入前判断：operator 能否把 role 分配给 target。角色配了分发部门（sys_role_allowed_dept）时，目标用户部门须在映射内，且操作者部门命中映射或能看见目标用户；未配时按 scope_dept_id 子树 + 能看见目标用户判断。操作者/角色/目标任一无效都返回 false。';


-- ------------------------------------------------------------
-- fn_can_operate_row：当前用户能否修改/删除某条数据
--
-- 判断标准很简单：能看见这条数据，就能操作它（读写同权）。
-- "能看见"指数据的归属字段命中该用户的可见范围，和动态查询
-- 列表时的过滤规则一致。
--
-- 参数：
--   p_user_id              当前用户
--   p_owner_user_id        这条数据的归属人（NULL = 没有归属人）
--   p_owner_dept_id        这条数据的归属部门（NULL = 没有归属部门）
--   p_owner_user_group_id  这条数据的归属用户组（NULL = 没有归属组）
--   后三个参数传这条数据当前的值：调用方先 SELECT ... FOR UPDATE
--   锁行取值再传入，避免并发修改归属后按旧值判断。
--
-- 判断逻辑（满足其一即 true）：
--   1. 当前用户有全租户角色（data_scope=7），直接通过；
--   2. 某个归属字段非空，且命中对应的可见范围：
--      归属人在可见用户列表内 / 归属部门在可见部门列表内 /
--      归属组在可见用户组列表内。
--   三个归属字段全为 NULL 的数据只有全租户角色能操作；
--   当前用户无效（不存在/禁用/删除）时永远不通过。
--
-- 返回：true = 允许操作；false = 拒绝。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_can_operate_row(p_user_id int8, p_owner_user_id int8, p_owner_dept_id int8, p_owner_user_group_id int8)
    RETURNS boolean
    STABLE
    LANGUAGE sql
AS $$
SELECT public.fn_accessible_user_ids(p_user_id) IS NULL
    OR public.fn_accessible_dept_ids(p_user_id) IS NULL
    OR public.fn_accessible_group_ids(p_user_id) IS NULL
    OR (p_owner_user_id IS NOT NULL AND p_owner_user_id = ANY (public.fn_accessible_user_ids(p_user_id)))
    OR (p_owner_dept_id IS NOT NULL AND p_owner_dept_id = ANY (public.fn_accessible_dept_ids(p_user_id)))
    OR (p_owner_user_group_id IS NOT NULL AND p_owner_user_group_id = ANY (public.fn_accessible_group_ids(p_user_id)))
$$;

COMMENT ON FUNCTION public.fn_can_operate_row(int8, int8, int8, int8) IS '写入前判断：当前用户能否操作一条数据（读写同权：能看见就能操作）。传入该数据当前的归属人/归属部门/归属用户组（NULL=无该归属）。有全租户角色直接通过；否则任一非空归属命中可见范围即通过；三个归属全空的数据只有全租户能操作；用户无效永远不通过。';


-- ------------------------------------------------------------
-- fn_can_transfer_owner：当前用户能否把某条数据的归属改给别人
--
-- 改归属要同时过两道检查：
--   1. 这条数据本身你有权操作（按它的旧归属判断）；
--   2. 新归属的人/部门/组在你的可见范围内。
-- 第二道是防止把数据转给自己根本看不见的人，造成数据外流。
--
-- 参数：
--   p_user_id              当前用户
--   p_old_owner_user_id    这条数据现在的归属人（NULL = 没有）
--   p_old_owner_dept_id    这条数据现在的归属部门（NULL = 没有）
--   p_old_owner_group_id   这条数据现在的归属用户组（NULL = 没有）
--   p_new_owner_user_id    要改成的归属人（NULL = 改完后没有）
--   p_new_owner_dept_id    要改成的归属部门（NULL = 改完后没有）
--   p_new_owner_group_id   要改成的归属用户组（NULL = 改完后没有）
--
-- 判断逻辑（同时满足才返回 true）：
--   1. 旧归属通过 fn_can_operate_row 的判断；
--   2. 新归属的每个非空字段都在对应可见范围内（新归属人在可见用户
--      列表内 / 新部门在可见部门列表内 / 新组在可见组列表内）。
--      当前用户有全租户角色时两道检查都直接通过。
--
-- 返回：true = 允许修改归属；false = 拒绝。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_can_transfer_owner(p_user_id int8,
                                                        p_old_owner_user_id int8,
                                                        p_old_owner_dept_id int8,
                                                        p_old_owner_group_id int8,
                                                        p_new_owner_user_id int8,
                                                        p_new_owner_dept_id int8,
                                                        p_new_owner_group_id int8)
    RETURNS boolean
    STABLE
    LANGUAGE sql
AS $$
SELECT public.fn_can_operate_row(p_user_id, p_old_owner_user_id, p_old_owner_dept_id, p_old_owner_group_id)
   -- 新归属目标可达：每个非空新值命中对应集合（NULL 集合 = 全租户放行该维）
   AND (public.fn_accessible_user_ids(p_user_id) IS NULL
        OR p_new_owner_user_id IS NULL
        OR p_new_owner_user_id = ANY (public.fn_accessible_user_ids(p_user_id)))
   AND (public.fn_accessible_dept_ids(p_user_id) IS NULL
        OR p_new_owner_dept_id IS NULL
        OR p_new_owner_dept_id = ANY (public.fn_accessible_dept_ids(p_user_id)))
   AND (public.fn_accessible_group_ids(p_user_id) IS NULL
        OR p_new_owner_group_id IS NULL
        OR p_new_owner_group_id = ANY (public.fn_accessible_group_ids(p_user_id)))
$$;

COMMENT ON FUNCTION public.fn_can_transfer_owner(int8, int8, int8, int8, int8, int8, int8) IS '写入前判断：能否把一条数据的归属从旧归属改为新归属。两道检查同时通过才允许：这条数据按旧归属判断你有权操作（fn_can_operate_row），且新归属的每个非空字段（人/部门/组）都在你的可见范围内。防止把数据转给自己看不见的人。';
