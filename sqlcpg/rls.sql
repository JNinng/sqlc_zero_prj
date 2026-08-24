-- ============================================================
-- rls.sql — 租户隔离 RLS + 行级守卫函数 + 演示数据库用户
--
-- 依赖：schema.sql（表结构与 @dynamic/@scope DSL 注释）。在 schema.sql 之后执行。
-- 本文件不是 sqlc 的输入：sqlc 不校验守卫函数存在性（函数名仅做拼接），
-- 部署侧保证 schema.sql → rls.sql → seed.sql 的执行顺序即可。
--
-- 内容：
--   1. fn_touch_updated_at 触发器（updated_at 兜底刷新，批量挂载）
--   2. 守卫函数三件套（@scope 的执行体， RETURNS TABLE 行集形态）
--   3. 21 张租户表的 RLS 租户隔离策略（ENABLE + FORCE，未设置默认全拒）
--   4. test_u 演示用户及授权（普通角色，真实承受 RLS；GRANT CONNECT ON
--      DATABASE 依赖库名，由部署方/example 动态执行，不在本文件）
--
-- 与 basic-db-table/fun.sql 的关系：三件套以 fn_perm_user_ids/fn_perm_dept_ids
-- 的语义为蓝本，数组三态契约（NULL=全租户 / {}=拒绝 / 数组=并集）完全同构，
-- 由插件 v0.1.2 的 in_any 守卫消费（生成 (fn IS NULL OR col = ANY(fn))）；
-- 差异仅一处：新增 fn_accessible_group_ids 补齐 owner_user_group_id 维度。
-- ============================================================


-- ============================================================
-- 1. updated_at 自动维护：UPDATE 时若应用层未显式赋值则兜底刷新
--    （updated_by 承载业务操作者身份，数据库无法获知，仍由应用层写入）
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_touch_updated_at()
    RETURNS trigger
    LANGUAGE plpgsql
AS
$function$
BEGIN
    IF NEW.updated_at IS NOT DISTINCT FROM OLD.updated_at THEN
        NEW.updated_at := CURRENT_TIMESTAMP;
    END IF;
    RETURN NEW;
END;
$function$
;

-- 为所有含 updated_at 列的表批量挂载 BEFORE UPDATE 触发器（重复执行安全）
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT c.relname AS tbl
        FROM pg_class c
                 JOIN pg_namespace n ON n.oid = c.relnamespace
                 JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'updated_at' AND NOT a.attisdropped
        WHERE n.nspname = 'public'
          AND c.relkind = 'r'
        LOOP
            EXECUTE format('DROP TRIGGER IF EXISTS trg_touch_updated_at ON public.%I', r.tbl);
            EXECUTE format('CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON public.%I
                            FOR EACH ROW EXECUTE FUNCTION public.fn_touch_updated_at()', r.tbl);
        END LOOP;
END
$$;


-- ============================================================
-- 2. 守卫函数三件套 —— @scope 声明的行级数据范围执行体
--
--    签名契约：只收当前用户 ID（ADR-0002）。角色 → data_scope 的推导在
--    函数内部完成（sys_user_role_mapping × sys_role），调用方无需也不可
--    传入范围参数；撤销角色对下一笔查询即时生效。
--
--    返回契约（数组三态，与 basic-db-table/fun.sql 的 fn_perm_* 完全同构，
--    由插件 v0.1.2 的 in_any 守卫消费，生成谓词
--    (fn(...) IS NULL OR col = ANY(fn(...)))，见 ADR-0005）：
--      NULL  不受限（任一有效角色 data_scope=7 全租户）→ 放行全部，
--            含无归属行。NULL 只能由该显式分支返回：in_any 是显式放行
--            方向，函数别处误返 NULL 会放开整表。
--      '{}'  拒绝一切（用户不存在/被禁用/被删除，或无任何有效角色）
--      数组  可见 ID 集合，多角色取并集去重
--
--    前置条件：会话已 SET app.tenant_id（事务级 set_config）。函数为
--    STABLE + SECURITY INVOKER，内部查询自动受各表 RLS 租户隔离约束
--    （漏设变量时 me/my_roles 皆为空 → 走 '{}' 拒绝分支，不会误入 NULL 放行）。
--
--    有效性判定（贯穿所有分支，同 fun.sql）：
--      当前用户   sys_user.status=1 且 deleted_at IS NULL
--      角色       sys_role.status=1 且 deleted_at IS NULL
--      范围明细   sys_role_id_scope.status=1 且 deleted_at IS NULL
--      目标用户   sys_user.status=1 且 deleted_at IS NULL
--      目标部门   sys_dept.status=1 且 deleted_at IS NULL
--      目标用户组 sys_user_group.status=1 且 deleted_at IS NULL
-- ============================================================

-- 2.1 有权访问的用户 ID 集合 → owner_user_id 守卫
CREATE OR REPLACE FUNCTION public.fn_accessible_user_ids(p_user_id int8)
    RETURNS int8[]
    STABLE
    LANGUAGE sql
AS $$
WITH me AS (
    SELECT u.id, u.owner_dept_id
    FROM public.sys_user u
    WHERE u.id = p_user_id
      AND u.status = 1
      AND u.deleted_at IS NULL
),
my_roles AS (
    SELECT r.id, r.data_scope
    FROM public.sys_role r
             JOIN public.sys_user_role_mapping m ON m.role_id = r.id
    WHERE m.user_id = p_user_id
      AND r.status = 1
      AND r.deleted_at IS NULL
),
scoped AS (
    -- data_scope=1 仅本人
    SELECT me.id AS user_id
    FROM me
             JOIN my_roles r ON r.data_scope = 1

    UNION

    -- data_scope=2 本部门
    SELECT u.id
    FROM me
             JOIN my_roles r ON r.data_scope = 2
             JOIN public.sys_user u ON u.owner_dept_id = me.owner_dept_id
    WHERE u.status = 1
      AND u.deleted_at IS NULL

    UNION

    -- data_scope=3 本部门及子部门（closure 含 depth=0 自身）
    SELECT u.id
    FROM me
             JOIN my_roles r ON r.data_scope = 3
             JOIN public.sys_dept_closure c ON c.ancestor_id = me.owner_dept_id
             JOIN public.sys_user u ON u.owner_dept_id = c.descendant_id
    WHERE u.status = 1
      AND u.deleted_at IS NULL

    UNION

    -- data_scope=4 指定人
    SELECT s.data_id
    FROM my_roles r
             JOIN public.sys_role_id_scope s ON s.role_id = r.id AND s."type" = 1
             JOIN public.sys_user u ON u.id = s.data_id
    WHERE r.data_scope = 4
      AND s.status = 1
      AND s.deleted_at IS NULL
      AND u.status = 1
      AND u.deleted_at IS NULL

    UNION

    -- data_scope=5 指定部门
    SELECT u.id
    FROM my_roles r
             JOIN public.sys_role_id_scope s ON s.role_id = r.id AND s."type" = 2
             JOIN public.sys_dept d ON d.id = s.data_id AND d.status = 1 AND d.deleted_at IS NULL
             JOIN public.sys_user u ON u.owner_dept_id = d.id
    WHERE r.data_scope = 5
      AND s.status = 1
      AND s.deleted_at IS NULL
      AND u.status = 1
      AND u.deleted_at IS NULL

    UNION

    -- data_scope=6 用户组（角色经 sys_role_id_scope type=3 指定的组，组内有效成员）
    SELECT gm.user_id
    FROM my_roles r
             JOIN public.sys_role_id_scope s ON s.role_id = r.id AND s."type" = 3
             JOIN public.sys_user_group g ON g.id = s.data_id AND g.status = 1 AND g.deleted_at IS NULL
             JOIN public.sys_user_group_mapping gm ON gm.group_id = g.id
             JOIN public.sys_user u ON u.id = gm.user_id
    WHERE r.data_scope = 6
      AND s.status = 1
      AND s.deleted_at IS NULL
      AND u.status = 1
      AND u.deleted_at IS NULL
)
SELECT CASE
           -- 用户不存在/被禁用/被删除：拒绝一切
           WHEN NOT EXISTS (SELECT 1 FROM me) THEN '{}'::int8[]
           -- 任一有效角色为全租户：不受限（显式放行，含无归属行）
           WHEN EXISTS (SELECT 1 FROM my_roles WHERE data_scope = 7) THEN NULL::int8[]
           -- 多角色并集；无有效角色时 array_agg 为 NULL，归一为空集合（默认拒绝）
           ELSE COALESCE((SELECT array_agg(DISTINCT user_id) FROM scoped), '{}'::int8[])
       END
$$;

COMMENT ON FUNCTION public.fn_accessible_user_ids(int8) IS '行级守卫：返回当前用户有权访问的用户 ID 数组（@scope owner_user_id 列的执行体，in_any 三态）。NULL=全租户不限(仅 data_scope=7 分支)；{}=拒绝一切；数组=多角色 data_scope 并集。需先 SET app.tenant_id，自动受 RLS 租户隔离';


-- 2.2 有权访问的部门 ID 集合 → owner_dept_id 守卫
CREATE OR REPLACE FUNCTION public.fn_accessible_dept_ids(p_user_id int8)
    RETURNS int8[]
    STABLE
    LANGUAGE sql
AS $$
WITH me AS (
    SELECT u.id, u.owner_dept_id
    FROM public.sys_user u
    WHERE u.id = p_user_id
      AND u.status = 1
      AND u.deleted_at IS NULL
),
my_roles AS (
    SELECT r.id, r.data_scope
    FROM public.sys_role r
             JOIN public.sys_user_role_mapping m ON m.role_id = r.id
    WHERE m.user_id = p_user_id
      AND r.status = 1
      AND r.deleted_at IS NULL
),
scoped AS (
    -- data_scope=1 仅本人：返回本人归属部门，保证本人数据在部门过滤下仍可见
    SELECT me.owner_dept_id AS dept_id
    FROM me
             JOIN my_roles r ON r.data_scope = 1
    WHERE me.owner_dept_id IS NOT NULL

    UNION

    -- data_scope=2 本部门
    SELECT me.owner_dept_id
    FROM me
             JOIN my_roles r ON r.data_scope = 2
    WHERE me.owner_dept_id IS NOT NULL

    UNION

    -- data_scope=3 本部门及子部门
    SELECT c.descendant_id
    FROM me
             JOIN my_roles r ON r.data_scope = 3
             JOIN public.sys_dept_closure c ON c.ancestor_id = me.owner_dept_id

    UNION

    -- data_scope=4 指定人：目标用户归属部门
    SELECT u.owner_dept_id
    FROM my_roles r
             JOIN public.sys_role_id_scope s ON s.role_id = r.id AND s."type" = 1
             JOIN public.sys_user u ON u.id = s.data_id
    WHERE r.data_scope = 4
      AND s.status = 1
      AND s.deleted_at IS NULL
      AND u.status = 1
      AND u.deleted_at IS NULL
      AND u.owner_dept_id IS NOT NULL

    UNION

    -- data_scope=5 指定部门
    SELECT d.id
    FROM my_roles r
             JOIN public.sys_role_id_scope s ON s.role_id = r.id AND s."type" = 2
             JOIN public.sys_dept d ON d.id = s.data_id
    WHERE r.data_scope = 5
      AND s.status = 1
      AND s.deleted_at IS NULL
      AND d.status = 1
      AND d.deleted_at IS NULL

    UNION

    -- data_scope=6 用户组：组内有效成员归属部门
    SELECT u.owner_dept_id
    FROM my_roles r
             JOIN public.sys_role_id_scope s ON s.role_id = r.id AND s."type" = 3
             JOIN public.sys_user_group g ON g.id = s.data_id AND g.status = 1 AND g.deleted_at IS NULL
             JOIN public.sys_user_group_mapping gm ON gm.group_id = g.id
             JOIN public.sys_user u ON u.id = gm.user_id
    WHERE r.data_scope = 6
      AND s.status = 1
      AND s.deleted_at IS NULL
      AND u.status = 1
      AND u.deleted_at IS NULL
      AND u.owner_dept_id IS NOT NULL
)
SELECT CASE
           WHEN NOT EXISTS (SELECT 1 FROM me) THEN '{}'::int8[]
           WHEN EXISTS (SELECT 1 FROM my_roles WHERE data_scope = 7) THEN NULL::int8[]
           ELSE COALESCE((SELECT array_agg(DISTINCT dept_id) FROM scoped), '{}'::int8[])
       END
$$;

COMMENT ON FUNCTION public.fn_accessible_dept_ids(int8) IS '行级守卫：返回当前用户有权访问的部门 ID 数组（@scope owner_dept_id 列的执行体，in_any 三态）。NULL=全租户不限(仅 data_scope=7 分支)；{}=拒绝一切；数组=多角色 data_scope 并集。需先 SET app.tenant_id，自动受 RLS 租户隔离';


-- 2.3 有权访问的用户组 ID 集合 → owner_user_group_id 守卫
--     仅两类角色产生组可见性：data_scope=6（角色经 type=3 指定的组）与
--     data_scope=7（全租户组，NULL 放行）；用户/部门类范围不授予组归属可见性。
CREATE OR REPLACE FUNCTION public.fn_accessible_group_ids(p_user_id int8)
    RETURNS int8[]
    STABLE
    LANGUAGE sql
AS $$
WITH me AS (
    SELECT u.id
    FROM public.sys_user u
    WHERE u.id = p_user_id
      AND u.status = 1
      AND u.deleted_at IS NULL
),
my_roles AS (
    SELECT r.id, r.data_scope
    FROM public.sys_role r
             JOIN public.sys_user_role_mapping m ON m.role_id = r.id
    WHERE m.user_id = p_user_id
      AND r.status = 1
      AND r.deleted_at IS NULL
),
scoped AS (
    -- data_scope=6 角色指定用户组
    SELECT s.data_id AS group_id
    FROM my_roles r
             JOIN public.sys_role_id_scope s ON s.role_id = r.id AND s."type" = 3
             JOIN public.sys_user_group g ON g.id = s.data_id AND g.status = 1 AND g.deleted_at IS NULL
    WHERE r.data_scope = 6
      AND s.status = 1
      AND s.deleted_at IS NULL
)
SELECT CASE
           WHEN NOT EXISTS (SELECT 1 FROM me) THEN '{}'::int8[]
           WHEN EXISTS (SELECT 1 FROM my_roles WHERE data_scope = 7) THEN NULL::int8[]
           ELSE COALESCE((SELECT array_agg(DISTINCT group_id) FROM scoped), '{}'::int8[])
       END
$$;

COMMENT ON FUNCTION public.fn_accessible_group_ids(int8) IS '行级守卫：返回当前用户有权访问的用户组 ID 数组（@scope owner_user_group_id 列的执行体，in_any 三态）。仅 data_scope=6（角色指定组）产生非空集合；NULL=全租户不限(仅 data_scope=7 分支)；{}=拒绝一切。需先 SET app.tenant_id，自动受 RLS 租户隔离';


-- ============================================================
-- 3. RLS 租户隔离策略（ADR-0001：租户维度由数据库兜底，
--    与 @scope 的数据范围维度正交）
--    未设置 app.tenant_id 时 current_setting(...,true) 返回 NULL，
--    比较结果恒为假 → 默认全拒。sys_config 为全局配置无 tenant_id，不启用 RLS。
-- ============================================================

-- basic
CREATE POLICY basic_tenant_isolation
    ON public.basic
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_dept
CREATE POLICY sys_dept_tenant_isolation
    ON public.sys_dept
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_dept_closure
CREATE POLICY sys_dept_closure_tenant_isolation
    ON public.sys_dept_closure
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_role
CREATE POLICY sys_role_tenant_isolation
    ON public.sys_role
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_role_id_scope
CREATE POLICY sys_role_id_scope_tenant_isolation
    ON public.sys_role_id_scope
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_role_allowed_dept
CREATE POLICY sys_role_allowed_dept_tenant_isolation
    ON public.sys_role_allowed_dept
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_tenant
-- 子租户行挂在父租户 tenant_id 下；USING/WITH CHECK 均允许命中自身 id，保证租户可读写自身行
CREATE POLICY sys_tenant_tenant_isolation
    ON public.sys_tenant
    USING (tenant_id = current_setting('app.tenant_id', true) OR id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true) OR id = current_setting('app.tenant_id', true));

-- sys_user
CREATE POLICY sys_user_tenant_isolation
    ON public.sys_user
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_user_role_mapping
CREATE POLICY sys_user_role_mapping_tenant_isolation
    ON public.sys_user_role_mapping
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_user_group
CREATE POLICY sys_user_group_tenant_isolation
    ON public.sys_user_group
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_user_group_mapping
CREATE POLICY sys_user_group_mapping_tenant_isolation
    ON public.sys_user_group_mapping
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_dict_type
CREATE POLICY sys_dict_type_tenant_isolation
    ON public.sys_dict_type
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_dict_data
CREATE POLICY sys_dict_data_tenant_isolation
    ON public.sys_dict_data
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_menu
CREATE POLICY sys_menu_tenant_isolation
    ON public.sys_menu
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_role_menu
CREATE POLICY sys_role_menu_tenant_isolation
    ON public.sys_role_menu
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_login_log
CREATE POLICY sys_login_log_tenant_isolation
    ON public.sys_login_log
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_operation_log
CREATE POLICY sys_operation_log_tenant_isolation
    ON public.sys_operation_log
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_session
CREATE POLICY sys_session_tenant_isolation
    ON public.sys_session
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_tenant_config
CREATE POLICY sys_tenant_config_tenant_isolation
    ON public.sys_tenant_config
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_feature_flag
CREATE POLICY sys_feature_flag_tenant_isolation
    ON public.sys_feature_flag
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- sys_translation
CREATE POLICY sys_translation_tenant_isolation
    ON public.sys_translation
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

ALTER TABLE public.basic
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.basic
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_dept
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_dept
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_dept_closure
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_dept_closure
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_role
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_role
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_role_id_scope
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_role_id_scope
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_role_allowed_dept
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_role_allowed_dept
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_tenant
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_tenant
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_user
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_user
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_user_role_mapping
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_user_role_mapping
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_user_group
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_user_group
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_user_group_mapping
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_user_group_mapping
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_dict_type
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_dict_type
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_dict_data
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_dict_data
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_menu
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_menu
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_role_menu
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_role_menu
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_login_log
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_login_log
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_operation_log
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_operation_log
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_session
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_session
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_tenant_config
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_tenant_config
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_feature_flag
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_feature_flag
    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sys_translation
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_translation
    FORCE ROW LEVEL SECURITY;


-- ============================================================
-- 4. test_u 演示用户及授权
--    普通数据库角色：真实承受 RLS 与 FORCE（超级用户会绕过 RLS，
--    演示/运行都必须走这类非超级用户连接）。重复执行安全。
--    GRANT CONNECT ON DATABASE <库名> TO test_u 依赖库名，
--    由部署方（example 的 setup）动态执行。
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'test_u') THEN
        CREATE USER test_u WITH PASSWORD 'test_u_pwd';
    END IF;
END
$$;

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO test_u;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO test_u;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO test_u;

-- 功能入口表对运行用户只读：写入走管理端（与 basic-db-table 的授权姿态一致）
REVOKE INSERT, UPDATE, DELETE ON public.sys_menu, public.sys_config FROM test_u;

-- 其他角色所建表不自动放行，需要时另行显式 GRANT
ALTER DEFAULT PRIVILEGES FOR ROLE CURRENT_USER IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO test_u;
ALTER DEFAULT PRIVILEGES FOR ROLE CURRENT_USER IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO test_u;

-- RLS 会话变量写入权（PG15+）：运行连接每事务 set_config('app.tenant_id',...) 的前提
GRANT SET ON PARAMETER app.tenant_id TO test_u;
