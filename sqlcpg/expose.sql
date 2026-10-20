-- ============================================================
-- expose.sql — 权限查询接口：读侧·面向外部进程的只读判定函数 + 范围版本
--
-- 在 schema.sql、rls.sql、operate.sql 之后，seed.sql 之前执行。
-- 本文件同时列在 sqlc.yaml 的 schema 里（同 operate.sql 的原因：
-- queries.sql 的命名查询要调用这些函数，sqlc 需要读到函数签名；
-- rls.sql 也因此纳入——GetScope 直接调 fn_accessible_* 三件套）。
--
-- 解决什么问题：
--   外部系统（不同进程、不同数据库）的数据以归属字段引用本库的
--   用户/部门/组 ID，需要：判断"操作者能否看见/操作某条数据"、
--   拉取可视范围、批量过滤（远程往返优化）、判断功能权限码。
--   这些查询由根级 perm/ 服务层暴露（传输无关，HTTP/gRPC 由宿主
--   自行包装），底层与内部 @scope 守卫共用同一套推导函数，
--   内外判定不分歧（ADR-0007）。
--
-- 三个查询判断函数（读写同权：能看见就能操作）：
--   fn_check_visible        单点判断：按指定维度判断一条归属是否可见
--   fn_filter_visible_rows  批量版：一次过滤一组归属，返回可见子集
--   fn_has_permission       功能权限轴：用户是否持有某权限码
--
-- 范围版本（ADR-0008）：
--   sys_perm_version 表 + bump 触发器。外部进程缓存判定结果后，
--   靠版本比对决定续用还是重拉；物理删除的角色映射变更也能捕获。
--
-- 注释约定：每个函数按「参数 → 判断逻辑 → 返回值」三段写；
-- 修改时同步这段注释、COMMENT ON 和 sqlcpg/README.md 里的索引。
-- ============================================================


-- ------------------------------------------------------------
-- fn_check_visible：当前用户能否看见/操作一条数据（按指定维度）
--
-- 与 fn_can_operate_row 同一套推导（读写同权），差别只在：
--   1. 只读暴露，不与写事务绑定（调用方不写库也要能判断）；
--   2. p_dims 指定参与判定的归属维度，只看选中维度。
--
-- 参数：
--   p_user_id           当前用户
--   p_dims              维度掩码：1 归属人、2 归属部门、4 归属用户组，
--                       可按位组合（7=全维度）。混合（组合多位）时
--                       选中维度按 OR 并集判定。
--   p_owner_user_id     这条数据的归属人（NULL = 没有）
--   p_owner_dept_id     这条数据的归属部门（NULL = 没有）
--   p_owner_user_group_id  这条数据的归属用户组（NULL = 没有）
--
-- 判断逻辑（选中维度逐个求值后取 OR）：
--   归属人维度：可见用户集为 NULL（全租户角色）通过；
--               否则归属人非空且命中可见用户集才通过。
--   归属部门、归属用户组维度同构。
--   用户无效（不存在/禁用/删除）时三个集合都是空数组，永远不通过；
--   p_dims 为 0（未选中任何维度）同样不通过；1/2/4 之外的位被忽略。
--
-- 返回：true = 可见（即可操作）；false = 拒绝（拒绝不是错误）。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_check_visible(p_user_id int8, p_dims int2, p_owner_user_id int8, p_owner_dept_id int8, p_owner_user_group_id int8)
    RETURNS boolean
    STABLE
    LANGUAGE sql
AS $$
SELECT ((p_dims & 1) <> 0 AND (
            public.fn_accessible_user_ids(p_user_id) IS NULL
            OR (p_owner_user_id IS NOT NULL
                AND p_owner_user_id = ANY (public.fn_accessible_user_ids(p_user_id)))))
    OR ((p_dims & 2) <> 0 AND (
            public.fn_accessible_dept_ids(p_user_id) IS NULL
            OR (p_owner_dept_id IS NOT NULL
                AND p_owner_dept_id = ANY (public.fn_accessible_dept_ids(p_user_id)))))
    OR ((p_dims & 4) <> 0 AND (
            public.fn_accessible_group_ids(p_user_id) IS NULL
            OR (p_owner_user_group_id IS NOT NULL
                AND p_owner_user_group_id = ANY (public.fn_accessible_group_ids(p_user_id)))))
$$;

COMMENT ON FUNCTION public.fn_check_visible(int8, int2, int8, int8, int8) IS '查询判断（只读）：当前用户按指定维度掩码（1人/2部门/4组，OR 并集）能否看见一条数据，读写同权。有全租户角色时选中维度直接通过；否则非空归属命中对应可见集合才通过；用户无效或掩码未选中任何维度（0）永远不通过。不与写事务绑定，拒绝返回 false 不是错误。';


-- ------------------------------------------------------------
-- fn_filter_visible_rows：fn_check_visible 的批量版
--
-- 一次传入一组归属三元组（外部系统自己库里的行），返回其中
-- 可见的子集——固定操作者、批量目标，只回允许的部分，供远程
-- 系统一次往返完成批量过滤。
--
-- 参数：
--   p_user_id        当前用户
--   p_dims           维度掩码（同 fn_check_visible）
--   p_owner_user_ids    归属人数组（下标对齐，无归属传 NULL 元素）
--   p_owner_dept_ids    归属部门数组（同上）
--   p_owner_group_ids   归属用户组数组（同上）
--
-- 判断逻辑：三个数组按下标对齐成一组归属三元组（unnest 多数组
-- 并行展开），逐条按 fn_check_visible 判断，只返回通过的行。
--
-- 返回：TABLE(owner_user_id, owner_dept_id, owner_user_group_id)——
--       可见子集，保持传入顺序；调用方按三元组自行对位。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_filter_visible_rows(p_user_id int8, p_dims int2,
                                                         p_owner_user_ids int8[],
                                                         p_owner_dept_ids int8[],
                                                         p_owner_group_ids int8[])
    RETURNS TABLE(owner_user_id int8, owner_dept_id int8, owner_user_group_id int8)
    STABLE
    LANGUAGE sql
AS $$
SELECT t.u, t.d, t.g
FROM unnest(p_owner_user_ids, p_owner_dept_ids, p_owner_group_ids) AS t(u, d, g)
WHERE public.fn_check_visible(p_user_id, p_dims, t.u, t.d, t.g)
$$;

COMMENT ON FUNCTION public.fn_filter_visible_rows(int8, int2, int8[], int8[], int8[]) IS '查询判断（只读）：fn_check_visible 的批量版。三个归属数组按下标对齐成一组三元组，逐条按维度掩码判断，只返回可见子集（保持传入顺序）。供外部系统一次往返批量过滤自己库里引用本库 ID 的行。';


-- ------------------------------------------------------------
-- fn_has_permission：当前用户是否持有某功能权限码
--
-- 功能权限轴的库内判定。与数据范围轴正交：只看角色 → 菜单 →
-- 权限码这条链，不管能看见哪些行。
--
-- 参数：
--   p_user_id  当前用户
--   p_code     权限码，如 'sys:user:create'（sys_menu.permission_code，
--              租户内唯一）
--
-- 判断逻辑：用户有效（启用、未删除）且任一有效角色（启用、未删除）
--   关联了携带该权限码的有效菜单（启用、未删除）。
--   RLS 已把查询限制在当前租户内，跨租户的权限码等同于不存在。
--
-- 返回：true = 持有；false = 不持有（或用户/权限码无效）。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_has_permission(p_user_id int8, p_code varchar)
    RETURNS boolean
    STABLE
    LANGUAGE sql
AS $$
SELECT EXISTS (SELECT 1
               FROM public.sys_user u
                        JOIN public.sys_user_role_mapping m ON m.user_id = u.id
                        JOIN public.sys_role r ON r.id = m.role_id
                        AND r.status = 1 AND r.deleted_at IS NULL
                        JOIN public.sys_role_menu rm ON rm.role_id = r.id
                        JOIN public.sys_menu mu ON mu.id = rm.menu_id
                        AND mu.status = 1 AND mu.deleted_at IS NULL
               WHERE u.id = p_user_id
                 AND u.status = 1
                 AND u.deleted_at IS NULL
                 AND mu.permission_code = p_code)
$$;

COMMENT ON FUNCTION public.fn_has_permission(int8, varchar) IS '查询判断（只读）：用户是否持有某功能权限码（角色→菜单→权限码，与数据范围正交）。用户、角色、菜单任一环无效即不持有。RLS 限定当前租户。';


-- ============================================================
-- 范围版本：sys_perm_version 表 + bump 触发器（ADR-0008）
--
-- 外部进程缓存可视范围/权限码结果是既定用法，必须有失效信号。
-- 影响判定结果的表里 sys_user_role_mapping、sys_role_id_scope、
-- sys_role_menu 是物理删除且无 updated_at，max(updated_at) 聚合
-- 对删除视而不见，所以版本由触发器维护。
--
-- 双粒度：
--   user_id = 0   租户级行——角色/菜单/组织侧变更 bump，
--                 该租户所有用户的缓存都要重拉；
--   user_id > 0   用户级行——该用户自身行/角色映射变更 bump，
--                 只失效这一个用户的缓存。
-- 缓存有效性 = 两个版本都未变（GetScopeVersion 一次取回两个）。
--
-- 契约：版本只用于相等比较，不承诺跨表有序；是失效信号，不是
-- 变更日志。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.sys_perm_version
(
    tenant_id  varchar(16)               NOT NULL,
    user_id    int8                      NOT NULL DEFAULT 0,
    version    int8                      NOT NULL DEFAULT 0,
    updated_at timestamp(0) DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT sys_perm_version_pkey PRIMARY KEY (tenant_id, user_id)
);

COMMENT ON TABLE public.sys_perm_version IS '范围版本表：外部进程缓存判定结果的失效信号（ADR-0008）。user_id=0 是租户级行（角色/菜单/组织侧变更 bump，全体缓存失效）；user_id>0 是用户级行（该用户自身行/角色映射变更 bump，只失效该用户）。版本只用于相等比较，由触发器维护，业务代码不直接写入。';

COMMENT ON COLUMN public.sys_perm_version.version IS '单调递增计数，从 1 开始；只比较是否变化，不比较大小语义';

ALTER TABLE public.sys_perm_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_perm_version FORCE ROW LEVEL SECURITY;

CREATE POLICY sys_perm_version_tenant_isolation
    ON public.sys_perm_version
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));


-- ------------------------------------------------------------
-- bump 函数：不存在则建行（version=1），存在则 +1。
-- 触发器统一走这里，业务代码不直接调用。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_bump_perm_version(p_tenant_id varchar, p_user_id int8)
    RETURNS void
    LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO public.sys_perm_version (tenant_id, user_id, version, updated_at)
    VALUES (p_tenant_id, p_user_id, 1, CURRENT_TIMESTAMP)
    ON CONFLICT (tenant_id, user_id)
    DO UPDATE SET version = public.sys_perm_version.version + 1, updated_at = CURRENT_TIMESTAMP;
END
$$;

COMMENT ON FUNCTION public.fn_bump_perm_version(varchar, int8) IS '范围版本自增（触发器专用）：p_user_id=0 bump 租户级行，>0 bump 该用户行。不存在的行从 1 起建。业务代码不直接调用。';


-- ------------------------------------------------------------
-- 触发器函数：按 TG_OP 从 OLD/NEW 取租户与用户，转发给 bump。
-- 全部 AFTER ROW 触发，RETURN NULL（不改写行内容）。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_touch_perm_version_user_row()
    RETURNS trigger
    LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM public.fn_bump_perm_version(OLD.tenant_id, OLD.id);
    ELSIF TG_OP = 'UPDATE' AND OLD.id IS DISTINCT FROM NEW.id THEN
        PERFORM public.fn_bump_perm_version(OLD.tenant_id, OLD.id);
        PERFORM public.fn_bump_perm_version(NEW.tenant_id, NEW.id);
    ELSE
        PERFORM public.fn_bump_perm_version(NEW.tenant_id, NEW.id);
    END IF;
    RETURN NULL;
END
$$;

COMMENT ON FUNCTION public.fn_touch_perm_version_user_row() IS '范围版本触发器（sys_user 专用）：按 TG_OP 从 OLD/NEW 取租户与用户并转 bump——DELETE 用 OLD，UPDATE 换 id 时两侧都 bump，其余用 NEW。RETURN NULL，不改写行内容。';

-- sys_user_role_mapping 专用：用户从 user_id 列取
CREATE OR REPLACE FUNCTION public.fn_touch_perm_version_mapping()
    RETURNS trigger
    LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM public.fn_bump_perm_version(OLD.tenant_id, OLD.user_id);
    ELSIF TG_OP = 'UPDATE' AND OLD.user_id IS DISTINCT FROM NEW.user_id THEN
        PERFORM public.fn_bump_perm_version(OLD.tenant_id, OLD.user_id);
        PERFORM public.fn_bump_perm_version(NEW.tenant_id, NEW.user_id);
    ELSE
        PERFORM public.fn_bump_perm_version(NEW.tenant_id, NEW.user_id);
    END IF;
    RETURN NULL;
END
$$;

COMMENT ON FUNCTION public.fn_touch_perm_version_mapping() IS '范围版本触发器（sys_user_role_mapping 专用）：从 user_id 列取用户并转 bump——DELETE 用 OLD，UPDATE 换用户时两侧都 bump，其余用 NEW。RETURN NULL。';

-- 角色侧/菜单侧/组织侧通用：一律 bump 租户级行（user_id=0）
CREATE OR REPLACE FUNCTION public.fn_touch_perm_version_tenant()
    RETURNS trigger
    LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM public.fn_bump_perm_version(OLD.tenant_id, 0);
    ELSE
        PERFORM public.fn_bump_perm_version(NEW.tenant_id, 0);
    END IF;
    RETURN NULL;
END
$$;

COMMENT ON FUNCTION public.fn_touch_perm_version_tenant() IS '范围版本触发器（角色/菜单/组织侧通用）：DELETE 用 OLD、其余用 NEW，统一 bump 租户级行（user_id=0）。RETURN NULL。';

-- ------------------------------------------------------------
-- 触发器挂载。用户级：只 bump 该用户；租户级：bump 租户行。
-- 挂载清单 = 判定函数的输入表清单，两处必须同步改（见文件头）。
-- ------------------------------------------------------------
-- 用户自身行：状态/软删/归属三元组变化影响"这个用户能看见什么"
-- （仅本人/本部门档位读自己的归属推导可见集）
CREATE TRIGGER trg_perm_version_user
    AFTER UPDATE OF status, deleted_at, owner_user_id, owner_dept_id, owner_user_group_id
    ON public.sys_user
    FOR EACH ROW EXECUTE FUNCTION public.fn_touch_perm_version_user_row();

-- 用户-角色映射：挂上/摘掉角色直接影响该用户全部判定
CREATE TRIGGER trg_perm_version_user_role
    AFTER INSERT OR UPDATE OR DELETE
    ON public.sys_user_role_mapping
    FOR EACH ROW EXECUTE FUNCTION public.fn_touch_perm_version_mapping();

-- 角色：data_scope/状态/软删影响该角色全部持有者
CREATE TRIGGER trg_perm_version_role
    AFTER UPDATE OF data_scope, status, deleted_at
    ON public.sys_role
    FOR EACH ROW EXECUTE FUNCTION public.fn_touch_perm_version_tenant();

-- 角色 ID 明细（data_scope=4/5/6 的指定集）：增删改影响该角色持有者
CREATE TRIGGER trg_perm_version_role_id_scope
    AFTER INSERT OR UPDATE OR DELETE
    ON public.sys_role_id_scope
    FOR EACH ROW EXECUTE FUNCTION public.fn_touch_perm_version_tenant();

-- 角色-菜单映射：影响该角色持有者的权限码集合
CREATE TRIGGER trg_perm_version_role_menu
    AFTER INSERT OR UPDATE OR DELETE
    ON public.sys_role_menu
    FOR EACH ROW EXECUTE FUNCTION public.fn_touch_perm_version_tenant();

-- 菜单：权限码/状态/软删变化影响全部持有者
CREATE TRIGGER trg_perm_version_menu
    AFTER UPDATE OF permission_code, status, deleted_at
    ON public.sys_menu
    FOR EACH ROW EXECUTE FUNCTION public.fn_touch_perm_version_tenant();

-- 部门：挂载/移动/删除改变部门子树，影响本部门及子部门档位的可见集
CREATE TRIGGER trg_perm_version_dept
    AFTER INSERT OR UPDATE OR DELETE
    ON public.sys_dept
    FOR EACH ROW EXECUTE FUNCTION public.fn_touch_perm_version_tenant();

-- 本文件在 rls.sql 的批量授权之后执行，显式补授（触发器以写入者
-- 身份 INSERT/UPDATE 版本表，读写两侧都要放行）
GRANT SELECT, INSERT, UPDATE ON public.sys_perm_version TO test_u;
