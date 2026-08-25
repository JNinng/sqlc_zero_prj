-- ============================================================
-- operate.sql — 操作权限判定函数（写侧执行体）
--
-- 依赖：schema.sql → rls.sql 之后、seed.sql 之前执行（判定函数内部
-- 调用守卫函数三件套，守卫函数依赖表结构）。本文件同时纳入 sqlc 的
-- schema 输入列表（sqlc.yaml），使 queries.sql 能以 named query 类型化
-- 调用判定函数；sqlc 只解析签名，函数体存在性由部署顺序保证。
--
-- 维度定位（CONTEXT）：操作权限 = "能否对某条已存在数据执行写动作"，
-- 与数据范围（读）、功能权限（入口）正交。规则：
--   读写同权    操作对象须落在操作者的数据范围内（守卫集合）
--   双向可达    归属转移要求旧行可达 + 新归属目标可达
--   先检后写    判定与写入同事务：判定为假 → 调用方回滚，绝不落库
--
-- 与读侧守卫（rls.sql）的关系：守卫函数回答"能看见什么"（List/Count
-- 自动注入，fail-closed）；判定函数回答"能动什么刀"（写动作前显式
-- 调用，布尔三态之外的显式拒绝）。两者共享同一套 data_scope 推导，
-- 撤销角色对读写两类判定同时即时生效。RLS WITH CHECK 仍只兜底租户
-- 隔离（ADR-0001 分层不变，ADR-0006）。
--
-- 使用范式（门面内，见 example/mod.go）：
--   BEGIN;
--   SELECT set_config('app.tenant_id', $tenant, true);
--   SELECT fn_can_assign_role($operator, $role, $target);   -- false → 回滚
--   INSERT / UPDATE ...;                                    -- 写入
--   COMMIT;
--
-- 判定函数参数多、语义关键：每个函数的参数含义、判定算法与返回语义
-- 均在函数前注释与 COMMENT ON FUNCTION 中成文，改动须同步两处。
-- ============================================================


-- ------------------------------------------------------------
-- fn_can_assign_role — 角色分配判定
-- （sys_role_allowed_dept 表注释成文规则的执行体与库内单一事实源）
--
-- 参数：
--   p_operator_id    int8  操作者用户 ID。
--                            - 其有效角色集决定数据范围（data_scope 推导，
--                              经 fn_accessible_user_ids 覆盖校验）
--                            - 其 owner_dept_id 决定是否命中角色分发映射，
--                              命中即豁免数据范围覆盖校验
--   p_role_id        int8  待分配角色 ID。取其两样事实参与判定：
--                            - sys_role_allowed_dept 有效映射部门集（有则为
--                              显式分发模式）
--                            - scope_dept_id 可分配部门子树（无映射时的
--                              通用约束；NULL = 全租户可分配）
--   p_target_user_id int8  被分配用户 ID。其 owner_dept_id 参与映射集/
--                          子树校验；其有效性（status=1、未软删）是硬前提。
--
-- 判定算法（任一步不满足即返回 false，无副作用）：
--   前提  操作者、角色、目标用户三者均存在且有效
--        （各表 RLS 已将查询限定在当前租户，跨租户即"不存在"）
--   分支一  角色存在有效映射（sys_role_allowed_dept）——显式分发优先：
--     硬条件  目标用户 owner_dept_id ∈ 映射部门集
--     放行    操作者 owner_dept_id ∈ 映射部门集（命中映射，豁免覆盖校验）
--             或 目标用户 ∈ 操作者可见用户集（data_scope 覆盖兜底；
--                操作者 data_scope=7 时守卫返回 NULL，视为覆盖一切）
--   分支二  无映射——通用逻辑：
--     硬条件  角色 scope_dept_id IS NULL
--             或 目标用户 owner_dept_id ∈ 闭包子树(scope_dept_id)（含自身）
--     放行    目标用户 ∈ 操作者可见用户集
--
-- 返回：boolean。true = 允许分配（可落 sys_user_role_mapping）；
--       false = 拒绝（调用方回滚并报 ErrDenied）。
-- 边界：role_type=1（系统预置）不加隐性特例，规则统一（ADR-0006）；
--       "角色列表仅对命中部门管理员可见"属读侧呈现策略，不在本判定范围。
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
    -- 角色的有效分发映射部门集（非空 = 显式分发模式）
    SELECT a.dept_id
    FROM public.sys_role_allowed_dept a
    WHERE a.role_id = p_role_id
      AND a.status = 1
      AND a.deleted_at IS NULL
),
subtree AS (
    -- scope_dept_id 可分配子树（closure 含 depth=0 自身）
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
              -- 分支一：显式映射优先
              WHEN EXISTS (SELECT 1 FROM allowed) THEN
                      t.owner_dept_id IN (SELECT dept_id FROM allowed)
                      AND (
                          -- 操作者命中映射 → 豁免数据范围覆盖校验
                          EXISTS (SELECT 1
                                  FROM operator o
                                  WHERE o.owner_dept_id IN (SELECT dept_id FROM allowed))
                          -- 否则 data_scope 覆盖兜底（守卫 NULL=全租户 → 覆盖一切）
                          OR public.fn_accessible_user_ids(p_operator_id) IS NULL
                          OR t.id = ANY (public.fn_accessible_user_ids(p_operator_id))
                      )
              -- 分支二：通用逻辑
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

COMMENT ON FUNCTION public.fn_can_assign_role(int8, int8, int8) IS '操作权限判定：操作者(p_operator_id)能否把角色(p_role_id)分配给目标用户(p_target_user_id)。成文规则（sys_role_allowed_dept/scope_dept_id）的执行体：有分发映射时目标部门须∈映射集，操作者命中映射豁免 data_scope 覆盖，否则须 data_scope 覆盖目标；无映射时 scope_dept_id 子树约束 + data_scope 覆盖。三者任一无效即 false。false=拒绝，先检后写';


-- ------------------------------------------------------------
-- fn_can_operate_row — 通用行操作判定（读写同权）
--
-- 参数：
--   p_user_id           int8  操作者用户 ID（其有效角色决定三个守卫集合；
--                              无效用户 → 守卫返回 '{}' → 恒 false，fail-closed）
--   p_owner_user_id     int8  行当前的归属用户 ID。NULL = 该行无用户归属。
--   p_owner_dept_id     int8  行当前的归属部门 ID。NULL = 无部门归属。
--   p_owner_user_group_id int8 行当前的归属用户组 ID。NULL = 无组归属。
--                              三个归属参数取自行的**当前值**（UPDATE 前
--                              先 SELECT 行并 FOR UPDATE，防止并发改归属
--                              后按旧值判定）。
--
-- 判定算法：
--   任一守卫集合为 NULL（操作者含 data_scope=7 全租户）→ true（可操作
--     任何本租户行，含无归属行）
--   否则 任一非空归属值命中对应守卫集合 → true
--   （全 NULL 归属的行仅全租户档可操作——三态契约的写侧推论，ADR-0005）
--
-- 返回：boolean。true = 允许对该行执行写动作（改归属、修改、软删）。
-- 表无关：归属三元组即本体系行权限的完整表达，传值即可判，无需按表登记。
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

COMMENT ON FUNCTION public.fn_can_operate_row(int8, int8, int8, int8) IS '操作权限判定（通用行）：操作者(p_user_id)能否操作一条归属三元组为(p_owner_user_id/p_owner_dept_id/p_owner_user_group_id)的行（NULL=无该维归属，取行当前值）。读写同权：任一守卫集合为 NULL（全租户）恒 true；否则任一非空归属命中对应集合；全 NULL 归属仅全租户可操作；无效操作者恒 false。false=拒绝，先检后写';


-- ------------------------------------------------------------
-- fn_can_transfer_owner — 归属转移判定（双向可达）
--
-- 参数：
--   p_user_id              int8  操作者用户 ID。
--   p_old_owner_user_id    int8  行当前归属用户 ID（NULL = 无）。旧行可达
--   p_old_owner_dept_id    int8  行当前归属部门 ID（NULL = 无）。  的判定
--   p_old_owner_group_id   int8  行当前归属用户组 ID（NULL = 无）。 输入。
--   p_new_owner_user_id    int8  转移后的归属用户 ID（NULL = 转移后无用户
--   p_new_owner_dept_id    int8  转移后的归属部门 ID（NULL = 无）
--   p_new_owner_group_id   int8  转移后的归属用户组 ID（NULL = 无）。
--                              新三元组是**目标状态**，通常三者至多其一
--                              非空（与 basic 模板的单归属习惯一致），
--                              但算法对任意组合均成立。
--
-- 判定算法（双向可达，缺一即 false）：
--   去向一  旧行可达：fn_can_operate_row(操作者, 旧三元组) 为 true
--           —— 够不着的行不能动刀
--   去向二  新目标可达：新三元组每个非空值命中对应守卫集合
--           （某集合为 NULL=全租户 → 该维放行一切）
--           —— 看不见的人不能接手数据，堵归属外流旁路
--
-- 返回：boolean。true = 允许执行 UPDATE 归属。
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

COMMENT ON FUNCTION public.fn_can_transfer_owner(int8, int8, int8, int8, int8, int8, int8) IS '操作权限判定（归属转移，双向可达）：操作者(p_user_id)把行归属从旧三元组(p_old_owner_*)改为新三元组(p_new_owner_*)。旧行须经 fn_can_operate_row 可操作，且新三元组每个非空值命中操作者对应守卫集合（NULL 集合=全租户放行）。堵"把数据转给范围外对象"的外流旁路。false=拒绝，先检后写';
