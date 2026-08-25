-- ============================================================
-- rls.sql — 租户隔离策略 + 读侧权限过滤函数 + 演示用户授权
--
-- 在 schema.sql 之后执行；不是 sqlc 的输入文件。
--
-- 内容：
--   1. fn_touch_updated_at 触发器：UPDATE 时兜底刷新 updated_at
--   2. 三个权限过滤函数：算出"当前用户能看到哪些用户/部门/用户组"，
--      动态查询（List/Count）会把结果自动拼进 WHERE
--   3. 21 张租户表的 RLS 策略：会话没设置 app.tenant_id 时什么都
--      读不到、写不进（默认全拒）
--   4. test_u 演示用户与授权（GRANT CONNECT 依赖库名，由部署方执行）
--
-- 这三个函数和 basic-db-table/fun.sql 里的 fn_perm_* 是同一套逻辑；
-- 区别只有一处：这里多一个 fn_accessible_group_ids，补上用户组维度。
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

COMMENT ON FUNCTION public.fn_touch_updated_at() IS '审计兜底：UPDATE 时若应用层未显式刷新 updated_at（NEW 与 OLD 相同）则代为刷新为 CURRENT_TIMESTAMP；由 rls.sql 的 DO 块批量挂载到所有含 updated_at 列的表。updated_by 承载操作者身份，数据库无法获知，仍由应用层写入';

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
-- 2. 权限过滤函数（读侧）：算出当前用户能看到哪些用户/部门/用户组
--
-- 动态查询会在 WHERE 里自动拼上类似这样的条件（由 schema.sql 表注释
-- 里的 @scope 声明驱动）：
--   owner_user_id = ANY(fn_accessible_user_ids(当前用户))
--
-- 三个函数都只接收当前用户 ID。这个用户有哪些角色、能看到什么范围，
-- 由函数内部查表得出，调用方不传任何权限参数。好处：应用层零权限
-- 代码，角色一撤销，下一次查询立刻生效。
--
-- 返回值三种情况：
--   NULL   用户有全租户角色（data_scope=7），什么都不过滤
--   '{}'   用户无效（不存在/禁用/删除）或没有任何有效角色，什么都看不到
--   数组   能看到的 ID 列表，多个角色取并集
--
-- 注意：NULL 只允许出现在 data_scope=7 的分支。写这些函数时，别的
-- 地方误返回 NULL 会把整张表放开（查询里的 NULL 是"放行"语义）。
--
-- 会话需要已设置 app.tenant_id：函数内部的查询同样受 RLS 限制，
-- 漏设置时查不到任何角色，返回 '{}'（什么都看不到，不会误放行）。
--
-- 各分支只统计有效数据：用户/角色/范围明细/目标对象都要求
-- status=1 且未删除。
-- ============================================================

-- fn_accessible_user_ids：当前用户能看到哪些用户（用于 owner_user_id 过滤）
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

    -- data_scope=6 用户组：角色指定的组，返回组内成员
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
           -- 用户无效（不存在/禁用/已删除）：什么都看不到
           WHEN NOT EXISTS (SELECT 1 FROM me) THEN '{}'::int8[]
           -- 有全租户角色：不过滤（NULL 只允许在这个分支返回）
           WHEN EXISTS (SELECT 1 FROM my_roles WHERE data_scope = 7) THEN NULL::int8[]
           -- 多个角色取并集；没有匹配到任何用户时为空数组（什么都看不到）
           ELSE COALESCE((SELECT array_agg(DISTINCT user_id) FROM scoped), '{}'::int8[])
       END
$$;

COMMENT ON FUNCTION public.fn_accessible_user_ids(int8) IS '权限过滤：返回当前用户能看到哪些用户（列表查询自动用于 owner_user_id 过滤）。NULL=有全租户角色，不过滤；{}=用户无效或没有有效角色，什么都看不到；数组=可见用户的 ID 列表，多个角色取并集。需要会话已设置 app.tenant_id。';


-- fn_accessible_dept_ids：当前用户能看到哪些部门（用于 owner_dept_id 过滤）
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
    -- data_scope=1 仅本人：也算上自己所在部门，
    -- 保证自己的数据在按部门过滤时仍能看到
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

    -- data_scope=6 用户组：组内成员所在的部门
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

COMMENT ON FUNCTION public.fn_accessible_dept_ids(int8) IS '权限过滤：返回当前用户能看到哪些部门（列表查询自动用于 owner_dept_id 过滤）。NULL=有全租户角色，不过滤；{}=用户无效或没有有效角色；数组=可见部门的 ID 列表。"仅本人"角色也会返回自己所在部门，保证自己的数据在按部门过滤时仍能看到。需要会话已设置 app.tenant_id。';


-- fn_accessible_group_ids：当前用户能看到哪些用户组（用于 owner_user_group_id 过滤）
-- 只有两种角色会返回结果：data_scope=6（角色在 sys_role_id_scope 里指定了
-- 用户组）和 data_scope=7（全部）；其他角色对用户组没有可见性。
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
    -- data_scope=6：角色指定的用户组
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

COMMENT ON FUNCTION public.fn_accessible_group_ids(int8) IS '权限过滤：返回当前用户能看到哪些用户组（列表查询自动用于 owner_user_group_id 过滤）。只有两种角色返回结果：角色指定了用户组（data_scope=6）和全租户（data_scope=7，NULL 不过滤）；其他情况为 {}（该维度什么都看不到）。需要会话已设置 app.tenant_id。';


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
