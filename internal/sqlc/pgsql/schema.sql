-- public.basic 定义

-- Drop table

-- DROP TABLE public.basic;

CREATE TABLE public.basic
(
    id                  int8                                                   NOT NULL,
    status              int2         DEFAULT 1                                 NOT NULL,
    created_by          int8                                                   NOT NULL,
    created_at          timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    updated_by          int8                                                   NOT NULL,
    updated_at          timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    deleted_at          timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    tenant_id           varchar(16)                                            NOT NULL,
    owner_user_id       int8                                                   NULL,
    owner_dept_id       int8                                                   NULL,
    owner_user_group_id int8                                                   NULL,
    CONSTRAINT sys_basic_pkey PRIMARY KEY (id),
    CONSTRAINT basic_status_chk CHECK (status IN (0, 1))
);
-- owner_* 归属索引：data_scope = 2/3/5/6 的行级过滤高频路径
CREATE INDEX idx_basic_owner_user ON public.basic USING btree (owner_user_id);
CREATE INDEX idx_basic_owner_dept ON public.basic USING btree (owner_dept_id);
CREATE INDEX idx_basic_owner_user_group ON public.basic USING btree (owner_user_group_id);
COMMENT ON TABLE public.basic IS '基础字段示例表 [@default_sort: created_at DESC @pk: id @page: 20/400]';

-- Column comments

COMMENT ON COLUMN public.basic.id IS '主键 ID [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.basic.status IS '数据状态，0：禁用、1：启用 [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.basic.created_by IS '创建人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.basic.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.basic.updated_by IS '更新人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.basic.updated_at IS '更新时间 [@dynamic: range @sortable]';
COMMENT ON COLUMN public.basic.deleted_at IS '删除时间 [@hidden]';
COMMENT ON COLUMN public.basic.tenant_id IS '租户 ID [@dynamic: exact @selectable]';
COMMENT ON COLUMN public.basic.owner_user_id IS '归属用户 ID [@dynamic: exact, in]';
COMMENT ON COLUMN public.basic.owner_dept_id IS '归属部门 ID [@dynamic: exact, in]';
COMMENT ON COLUMN public.basic.owner_user_group_id IS '归属用户组 ID [@dynamic: exact, in]';


-- public.sys_dept 定义

-- Drop table

-- DROP TABLE public.sys_dept;

CREATE TABLE public.sys_dept
(
    id                  int8                                                   NOT NULL,
    status              int2         DEFAULT 1                                 NOT NULL,
    "name"              varchar(256)                                           NOT NULL,
    parent_id           int8                                                   NULL,
    created_by          int8                                                   NOT NULL,
    created_at          timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    updated_by          int8                                                   NOT NULL,
    updated_at          timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    deleted_at          timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    tenant_id           varchar(16)                                            NOT NULL,
    owner_user_id       int8                                                   NOT NULL,
    owner_user_group_id int8                                                   NULL,
    CONSTRAINT sys_dept_pkey PRIMARY KEY (id),
    CONSTRAINT sys_dept_status_chk CHECK (status IN (0, 1))
);
CREATE UNIQUE INDEX sys_dept_tenant_name_un ON public.sys_dept USING btree (tenant_id, name) WHERE deleted_at IS NULL;
COMMENT ON TABLE public.sys_dept IS '部门表 [@default_sort: created_at DESC @pk: id @page: 20/400]';

-- Column comments

COMMENT ON COLUMN public.sys_dept.id IS '部门 ID [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_dept.status IS '数据状态，0：禁用、1：启用 [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_dept."name" IS '部门名 [@dynamic: fuzzy, exact @sortable @selectable]';
COMMENT ON COLUMN public.sys_dept.parent_id IS '父级部门 ID [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_dept.created_by IS '创建人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_dept.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.sys_dept.updated_by IS '更新人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_dept.updated_at IS '更新时间 [@dynamic: range @sortable]';
COMMENT ON COLUMN public.sys_dept.deleted_at IS '删除时间 [@hidden]';
COMMENT ON COLUMN public.sys_dept.tenant_id IS '租户 ID [@dynamic: exact @selectable]';
COMMENT ON COLUMN public.sys_dept.owner_user_id IS '部门管理员用户 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_dept.owner_user_group_id IS '归属用户组 ID [@dynamic: exact, in]';

-- DROP FUNCTION public.fn_maintain_dept_closure();

-- 闭包表维护触发器函数，语义约定：
--   1. 输入校验：拒绝自身为父、父级不存在/已删除/跨租户、移入自身子树（环）
--   2. 软删除（UPDATE deleted_at -> NOT NULL）等价于 DELETE 分支：移除闭包路径；
--      恢复（UPDATE deleted_at -> NULL）等价于 INSERT 分支：重建闭包路径
--   3. 删除（软删/物理删）时若存在未删除子部门则拒绝，需自叶向根逐层删除
--   4. DELETE 清理范围为 {X 的祖先 ∪ X} × {X 的子树}，保留子树内部关系
CREATE
    OR REPLACE
    FUNCTION public.fn_maintain_dept_closure()
    RETURNS trigger
    LANGUAGE plpgsql
AS
$function$
DECLARE
    v_old_parent_id INT8;
    v_new_parent_id INT8;
    v_is_soft_del   BOOLEAN;
    v_is_restore    BOOLEAN;
BEGIN
    v_old_parent_id := OLD.parent_id;
    v_new_parent_id := NEW.parent_id;
    v_is_soft_del := (TG_OP = 'UPDATE' AND OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL);
    v_is_restore := (TG_OP = 'UPDATE' AND OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL);

    -- ================= 0. 输入校验 =================
    -- 新增 / 恢复 / 移动 时校验父级合法性与环
    IF (TG_OP = 'INSERT' OR v_is_restore
        OR (TG_OP = 'UPDATE' AND NOT v_is_soft_del)) THEN
        IF (v_new_parent_id = NEW.id) THEN
            RAISE EXCEPTION '部门 % 不能以自身为父级', NEW.id;
        END IF;
        IF (v_new_parent_id IS NOT NULL AND NOT EXISTS (SELECT 1
                                                        FROM sys_dept
                                                        WHERE id = NEW.parent_id
                                                          AND tenant_id = NEW.tenant_id
                                                          AND deleted_at IS NULL)) THEN
            RAISE EXCEPTION '父部门 % 不存在、已删除或跨租户', NEW.parent_id;
        END IF;
    END IF;

-- 移动时检测环：目标父级不能位于当前节点的子树内
    IF (TG_OP = 'UPDATE' AND NOT v_is_soft_del AND v_new_parent_id IS NOT NULL
        AND v_new_parent_id IS DISTINCT FROM v_old_parent_id
        AND EXISTS (SELECT 1
                    FROM sys_dept_closure
                    WHERE ancestor_id = OLD.id
                      AND descendant_id = NEW.parent_id)) THEN
        RAISE EXCEPTION '不能将部门 % 移入其自身子树（目标父级: %）', OLD.id, NEW.parent_id;
    END IF;

-- ================= 1. 新增 / 恢复部门 =================
    IF (TG_OP = 'INSERT' OR v_is_restore) THEN
        -- 插入自身到自身的路径 (深度0)
        INSERT INTO sys_dept_closure (ancestor_id, descendant_id, depth, tenant_id)
        VALUES (NEW.id, NEW.id, 0, NEW.tenant_id);

-- 如果有父节点，复制父节点的所有祖先关系，并指向新节点（深度+1）
        IF NEW.parent_id IS NOT NULL THEN
            INSERT INTO sys_dept_closure (ancestor_id, descendant_id, depth, tenant_id)
            SELECT c.ancestor_id, NEW.id, c.depth + 1, NEW.tenant_id
            FROM sys_dept_closure c
            WHERE c.descendant_id = NEW.parent_id;
        END IF;

        RETURN NEW;
    END IF;

-- ================= 2. 删除部门（物理删除 / 软删除） =================
    IF (TG_OP = 'DELETE' OR v_is_soft_del) THEN
        -- 存在未删除的子部门则拒绝删除，需先处理子部门（自叶向根）
        IF EXISTS (SELECT 1
                   FROM sys_dept
                   WHERE parent_id = OLD.id
                     AND deleted_at IS NULL) THEN
            RAISE EXCEPTION '部门 % 存在未删除的子部门，禁止删除，请先处理子部门', OLD.id;
        END IF;

        -- 正确的清理范围：{X 的祖先 ∪ X} × {X 的子树}
-- 只删除经过 X 的路径，保留子树内部关系，后续移动可正常重建
        DELETE
        FROM sys_dept_closure
        WHERE descendant_id IN (SELECT descendant_id
                                FROM sys_dept_closure
                                WHERE ancestor_id = OLD.id)
          AND ancestor_id IN (SELECT ancestor_id
                              FROM sys_dept_closure
                              WHERE descendant_id = OLD.id);
        RETURN OLD;
    END IF;

-- ================= 3. 移动部门 (修改 parent_id) =================
    IF (TG_OP = 'UPDATE' AND v_new_parent_id IS DISTINCT FROM v_old_parent_id) THEN
        -- 步骤 A: 断开旧关系
        -- 删除 "旧祖先 -> 该节点及其子节点" 的路径
        DELETE
        FROM sys_dept_closure
        WHERE descendant_id IN (SELECT descendant_id FROM sys_dept_closure WHERE ancestor_id = OLD.id) -- 后代
          AND ancestor_id IN
              (SELECT ancestor_id FROM sys_dept_closure WHERE descendant_id = OLD.id AND ancestor_id != OLD.id);
        -- 旧祖先(排除自身)

-- 步骤 B: 建立新关系
-- 插入 "新祖先 -> 该节点及其子节点" 的路径
        IF NEW.parent_id IS NOT NULL THEN
            INSERT INTO sys_dept_closure (ancestor_id, descendant_id, depth, tenant_id)
            SELECT a.ancestor_id, d.descendant_id, a.depth + d.depth + 1, NEW.tenant_id
            FROM sys_dept_closure a -- 新的祖先路径
                     CROSS JOIN sys_dept_closure d -- 当前节点及其子节点的路径
            WHERE a.descendant_id = NEW.parent_id -- 新祖先路径的终点是新父节点
              AND d.ancestor_id = NEW.id          -- 子路径的起点是当前节点
              AND a.ancestor_id != d.descendant_id; -- 避免产生环（自己不能是自己的祖先）
        END IF;

        RETURN NEW;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$function$
;

-- Table Triggers
-- 监听 deleted_at：软删除等价 DELETE 分支、恢复等价 INSERT 分支（见函数头注释）

DROP TRIGGER IF EXISTS trg_maintain_dept_closure ON public.sys_dept;

create trigger trg_maintain_dept_closure
    after
        insert
        or
        delete
        or
        update
            of parent_id, deleted_at
    on
        public.sys_dept
    for each row
execute function fn_maintain_dept_closure();


-- public.sys_dept_closure 定义

-- Drop table

-- DROP TABLE public.sys_dept_closure;

CREATE TABLE public.sys_dept_closure
(
    ancestor_id   int8        NOT NULL,
    descendant_id int8        NOT NULL,
    "depth"       int4        NOT NULL,
    tenant_id     varchar(16) NOT NULL,
    CONSTRAINT sys_dept_closure_pkey PRIMARY KEY (ancestor_id, descendant_id)
);
CREATE INDEX idx_closure_ancestor ON public.sys_dept_closure USING btree (ancestor_id);
CREATE INDEX idx_closure_descendant ON public.sys_dept_closure USING btree (descendant_id);
CREATE INDEX idx_closure_tenant ON public.sys_dept_closure USING btree (tenant_id);
COMMENT ON TABLE public.sys_dept_closure IS '部门闭包表。派生数据：由 trg_maintain_dept_closure 触发器随 sys_dept 增删改自动维护，可随时从部门树重建，因此不设审计字段（created_by 等），审计请看 sys_dept 本表';

-- Column comments

COMMENT ON COLUMN public.sys_dept_closure.ancestor_id IS '祖先节点ID';
COMMENT ON COLUMN public.sys_dept_closure.descendant_id IS '后代节点ID';
COMMENT ON COLUMN public.sys_dept_closure."depth" IS '深度/距离（0表示自身，1表示直接子节点，2表示孙子节点...）';
COMMENT ON COLUMN public.sys_dept_closure.tenant_id IS '租户 ID';


-- public.sys_role 定义

-- Drop table

-- DROP TABLE public.sys_role;

CREATE TABLE public.sys_role
(
    id            int8                                                   NOT NULL,
    status        int2         DEFAULT 1                                 NOT NULL,
    "name"        varchar(256)                                           NOT NULL,
    code          varchar(64)                                            NOT NULL,
    role_type     int2         DEFAULT 2                                 NOT NULL,
    data_scope    int2         DEFAULT 1                                 NOT NULL,
    scope_dept_id int8                                                   NULL,
    remark        varchar(512)                                           NULL,
    created_by    int8                                                   NOT NULL,
    created_at    timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    updated_by    int8                                                   NOT NULL,
    updated_at    timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    deleted_at    timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    tenant_id     varchar(16)                                            NOT NULL,
    CONSTRAINT sys_role_pkey PRIMARY KEY (id),
    CONSTRAINT sys_role_status_chk CHECK (status IN (0, 1)),
    CONSTRAINT sys_role_type_chk CHECK (role_type IN (1, 2)),
    CONSTRAINT sys_role_data_scope_chk CHECK (data_scope BETWEEN 1 AND 7)
);
CREATE UNIQUE INDEX sys_role_tenant_code_un ON public.sys_role USING btree (tenant_id, code) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX sys_role_tenant_name_un ON public.sys_role USING btree (tenant_id, name) WHERE deleted_at IS NULL;
COMMENT ON TABLE public.sys_role IS '角色表 [@default_sort: created_at DESC @pk: id @page: 20/400]';

-- Column comments

COMMENT ON COLUMN public.sys_role.id IS '主键 ID [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_role.status IS '数据状态，0：禁用、1：启用 [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_role."name" IS '角色名 [@dynamic: fuzzy, exact @sortable @selectable]';
COMMENT ON COLUMN public.sys_role.code IS '权限编码 [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_role.role_type IS '角色类型：1-系统预置(不可删除，核心权限不可剥离) 2-租户自定义 [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_role.data_scope IS '数据范围规则：1-仅本人 2-本部门 3-本部门及子部门 4-指定人 5-指定部门 6-用户组 7-全租户 [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_role.scope_dept_id IS '组织可见范围：限定角色可分配的部门层级。NULL=全租户可分配，具体部门ID=仅该部门及子部门可分配 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_role.remark IS '备注 [@dynamic: fuzzy @selectable]';
COMMENT ON COLUMN public.sys_role.created_by IS '创建人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_role.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.sys_role.updated_by IS '更新人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_role.updated_at IS '更新时间 [@dynamic: range @sortable]';
COMMENT ON COLUMN public.sys_role.deleted_at IS '删除时间 [@hidden]';
COMMENT ON COLUMN public.sys_role.tenant_id IS '租户 ID [@dynamic: exact @selectable]';


-- public.sys_role_id_scope 定义

-- Drop table

-- DROP TABLE public.sys_role_id_scope;

CREATE TABLE public.sys_role_id_scope
(
    id         int8                                                   NOT NULL,
    status     int2         DEFAULT 1                                 NOT NULL,
    "type"     int2         DEFAULT 1                                 NOT NULL,
    role_id    int8                                                   NOT NULL,
    data_id    int8                                                   NOT NULL,
    created_by int8                                                   NOT NULL,
    created_at timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    updated_by int8                                                   NOT NULL,
    updated_at timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    deleted_at timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    tenant_id  varchar(16)                                            NOT NULL,
    CONSTRAINT sys_role_id_scope_pkey PRIMARY KEY (id),
    CONSTRAINT sys_role_id_scope_status_chk CHECK (status IN (0, 1)),
    CONSTRAINT sys_role_id_scope_type_chk CHECK ("type" BETWEEN 1 AND 3)
);
CREATE UNIQUE INDEX sys_role_id_scope_tenant_role_type_data_un ON public.sys_role_id_scope USING btree (tenant_id, role_id, type, data_id) WHERE deleted_at IS NULL;
COMMENT ON TABLE public.sys_role_id_scope IS '角色数据 ID 范围表 [@default_sort: created_at DESC @pk: id @page: 20/400]';

-- Column comments

COMMENT ON COLUMN public.sys_role_id_scope.id IS '主键 ID [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_role_id_scope.status IS '数据状态，0：禁用、1：启用 [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_role_id_scope."type" IS '数据 ID 类型，1：用户ID、2：部门ID、3：用户组ID [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_role_id_scope.role_id IS '角色 ID [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_role_id_scope.data_id IS '数据 ID [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_role_id_scope.created_by IS '创建人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_role_id_scope.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.sys_role_id_scope.updated_by IS '更新人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_role_id_scope.updated_at IS '更新时间 [@dynamic: range @sortable]';
COMMENT ON COLUMN public.sys_role_id_scope.deleted_at IS '删除时间 [@hidden]';
COMMENT ON COLUMN public.sys_role_id_scope.tenant_id IS '租户 ID [@dynamic: exact @selectable]';


-- public.sys_role_allowed_dept 定义

-- Drop table

-- DROP TABLE public.sys_role_allowed_dept;

CREATE TABLE public.sys_role_allowed_dept
(
    id         int8                                                   NOT NULL,
    status     int2         DEFAULT 1                                 NOT NULL,
    role_id    int8                                                   NOT NULL,
    dept_id    int8                                                   NOT NULL,
    created_by int8                                                   NOT NULL,
    created_at timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    updated_by int8                                                   NOT NULL,
    updated_at timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    deleted_at timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    tenant_id  varchar(16)                                            NOT NULL,
    CONSTRAINT sys_role_allowed_dept_pkey PRIMARY KEY (id),
    CONSTRAINT sys_role_allowed_dept_status_chk CHECK (status IN (0, 1))
);
CREATE UNIQUE INDEX sys_role_allowed_dept_tenant_role_dept_un ON public.sys_role_allowed_dept USING btree (tenant_id, role_id, dept_id) WHERE deleted_at IS NULL;
COMMENT ON TABLE public.sys_role_allowed_dept IS '角色分发部门映射表（sys_role.allowed_dept_ids 集合的落地）。判定规则：角色无映射记录=遵循通用逻辑（scope_dept_id + data_scope 兜底）；有映射=映射分发角色，显式映射优先——角色列表仅对 dept_id 命中的部门管理员可见；分配时命中映射的操作者豁免 data_scope 覆盖校验，但目标用户所属部门必须存在于映射集合中；用户最终数据访问边界仍由角色 data_scope 决定，与分配逻辑解耦 [@default_sort: created_at DESC @pk: id @page: 20/400]';

-- Column comments

COMMENT ON COLUMN public.sys_role_allowed_dept.id IS '主键 ID [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_role_allowed_dept.status IS '数据状态，0：禁用、1：启用 [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_role_allowed_dept.role_id IS '角色 ID [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_role_allowed_dept.dept_id IS '允许分配该角色的部门 ID（映射分发范围） [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_role_allowed_dept.created_by IS '创建人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_role_allowed_dept.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.sys_role_allowed_dept.updated_by IS '更新人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_role_allowed_dept.updated_at IS '更新时间 [@dynamic: range @sortable]';
COMMENT ON COLUMN public.sys_role_allowed_dept.deleted_at IS '删除时间 [@hidden]';
COMMENT ON COLUMN public.sys_role_allowed_dept.tenant_id IS '租户 ID [@dynamic: exact @selectable]';


-- public.sys_tenant 定义

-- Drop table

-- DROP TABLE public.sys_tenant;

CREATE TABLE public.sys_tenant
(
    id             varchar(16)                                            NOT NULL,
    status         int2         DEFAULT 1                                 NOT NULL,
    code           varchar(32)                                            NOT NULL,
    "name"         varchar(256)                                           NOT NULL,
    parent_id      varchar(16)                                            NULL,
    contact_name   varchar(64)                                            NULL,
    contact_phone  varchar(32)                                            NULL,
    expired_at     timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    max_user_count int4                                                   NULL,
    default_locale varchar(10)  DEFAULT 'zh-CN'::character varying        NOT NULL,
    created_by     int8                                                   NOT NULL,
    created_at     timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    updated_by     int8                                                   NOT NULL,
    updated_at     timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    deleted_at     timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    tenant_id      varchar(16)                                            NOT NULL,
    CONSTRAINT sys_tenant_pk PRIMARY KEY (id),
    CONSTRAINT sys_tenant_status_chk CHECK (status IN (0, 1))
);
-- 软删除后名称/编码可复用：用部分唯一索引替代表级 UNIQUE 约束（与其他表模式一致）
CREATE UNIQUE INDEX sys_tenant_name_un ON public.sys_tenant USING btree (name) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX sys_tenant_code_un ON public.sys_tenant USING btree (code) WHERE deleted_at IS NULL;
COMMENT ON TABLE public.sys_tenant IS '租户表 [@default_sort: created_at DESC @pk: id @page: 20/400]';

-- Column comments

COMMENT ON COLUMN public.sys_tenant.id IS '租户 ID [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_tenant.status IS '数据状态，0：禁用、1：启用 [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_tenant.code IS '租户编码 [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_tenant."name" IS '租户名 [@dynamic: fuzzy, exact @sortable @selectable]';
COMMENT ON COLUMN public.sys_tenant.parent_id IS '父级租户 ID [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_tenant.contact_name IS '联系人 [@dynamic: fuzzy @selectable]';
COMMENT ON COLUMN public.sys_tenant.contact_phone IS '联系电话 [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_tenant.expired_at IS '到期时间 [@dynamic: range, is_null, not_null @sortable]';
COMMENT ON COLUMN public.sys_tenant.max_user_count IS '最大用户数 [@dynamic: exact, in, range @sortable]';
COMMENT ON COLUMN public.sys_tenant.default_locale IS '租户默认语言（BCP-47），如 zh-CN、en-US，新建用户时继承此值 [@dynamic: exact @selectable]';
COMMENT ON COLUMN public.sys_tenant.created_by IS '创建人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_tenant.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.sys_tenant.updated_by IS '更新人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_tenant.updated_at IS '更新时间 [@dynamic: range @sortable]';
COMMENT ON COLUMN public.sys_tenant.deleted_at IS '删除时间 [@hidden]';
COMMENT ON COLUMN public.sys_tenant.tenant_id IS '租户 ID [@dynamic: exact @selectable]';


-- public.sys_user 定义

-- Drop table

-- DROP TABLE public.sys_user;

CREATE TABLE public.sys_user
(
    id                  int8                                                   NOT NULL,
    status              int2         DEFAULT 1                                 NOT NULL,
    "name"              varchar(256)                                           NOT NULL,
    nickname            varchar(256)                                           NOT NULL,
    "password"          text                                                   NOT NULL,
    email               varchar(256)                                           NULL,
    phone               varchar(32)                                            NULL,
    remark              varchar(512)                                           NULL,
    locale              varchar(10)  DEFAULT 'zh-CN'::character varying        NOT NULL,
    last_login_at       timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    failed_count        int4         DEFAULT 0                                 NOT NULL,
    locked_until        timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    created_by          int8                                                   NOT NULL,
    created_at          timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    updated_by          int8                                                   NOT NULL,
    updated_at          timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    deleted_at          timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    tenant_id           varchar(16)                                            NOT NULL,
    owner_user_id       int8                                                   NULL,
    owner_dept_id       int8                                                   NULL,
    owner_user_group_id int8                                                   NULL,
    CONSTRAINT sys_user_pkey PRIMARY KEY (id),
    CONSTRAINT sys_user_status_chk CHECK (status IN (0, 1))
);
CREATE UNIQUE INDEX sys_user_tenant_name_un ON public.sys_user USING btree (tenant_id, name) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX sys_user_tenant_email_un ON public.sys_user USING btree (tenant_id, email) WHERE deleted_at IS NULL AND email IS NOT NULL;
CREATE UNIQUE INDEX sys_user_tenant_phone_un ON public.sys_user USING btree (tenant_id, phone) WHERE deleted_at IS NULL AND phone IS NOT NULL;
COMMENT ON TABLE public.sys_user IS '用户表 [@default_sort: created_at DESC @pk: id @page: 20/400]';

-- Column comments

COMMENT ON COLUMN public.sys_user.id IS '用户 ID [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_user.status IS '数据状态，0：禁用、1：启用 [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_user."name" IS '用户名 [@dynamic: fuzzy, exact @sortable @selectable]';
COMMENT ON COLUMN public.sys_user.nickname IS '昵称 [@dynamic: fuzzy, exact @sortable @selectable]';
COMMENT ON COLUMN public.sys_user."password" IS '密码 [@hidden]';
COMMENT ON COLUMN public.sys_user.email IS '邮箱 [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_user.phone IS '手机号 [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_user.locale IS '用户语言偏好（BCP-47），如 zh-CN、en-US，影响界面展示语言和查询回退优先级 [@dynamic: exact @selectable]';
COMMENT ON COLUMN public.sys_user.last_login_at IS '最后登录时间 [@dynamic: range, is_null, not_null @sortable]';
COMMENT ON COLUMN public.sys_user.failed_count IS '连续密码错误次数，达到 sys_config 的 auth.lockout-threshold 后锁定，登录成功清零（不依赖扫日志统计） [@dynamic: exact, in, range @sortable]';
COMMENT ON COLUMN public.sys_user.locked_until IS '账号锁定截止时间，NULL 表示未锁定，登录时 CURRENT_TIMESTAMP >= locked_until 视为已解锁 [@dynamic: range, is_null, not_null]';
COMMENT ON COLUMN public.sys_user.remark IS '备注 [@dynamic: fuzzy @selectable]';
COMMENT ON COLUMN public.sys_user.created_by IS '创建人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_user.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.sys_user.updated_by IS '更新人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_user.updated_at IS '更新时间 [@dynamic: range @sortable]';
COMMENT ON COLUMN public.sys_user.deleted_at IS '删除时间 [@hidden]';
COMMENT ON COLUMN public.sys_user.tenant_id IS '租户 ID [@dynamic: exact @selectable]';
COMMENT ON COLUMN public.sys_user.owner_user_id IS '归属用户 ID [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_user.owner_dept_id IS '归属部门 ID [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_user.owner_user_group_id IS '归属用户组 ID [@dynamic: exact, in]';


-- public.sys_user_role_mapping 定义

-- Drop table

-- DROP TABLE public.sys_user_role_mapping;

CREATE TABLE public.sys_user_role_mapping
(
    user_id    int8                                   NOT NULL,
    role_id    int8                                   NOT NULL,
    tenant_id  varchar(16)                            NOT NULL,
    created_by int8                                   NOT NULL,
    created_at timestamp(0) DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT sys_user_role_mapping_pkey PRIMARY KEY (user_id, role_id)
);
CREATE INDEX idx_surm_tenant ON public.sys_user_role_mapping USING btree (tenant_id);
CREATE INDEX idx_surm_role_id ON public.sys_user_role_mapping USING btree (role_id);

-- Column comments

COMMENT ON TABLE public.sys_user_role_mapping IS '用户-角色映射表。映射行无可变业务字段，解除关联走物理删除，因此仅保留 created_by/created_at 最小审计字段（谁在何时授予），不含 updated_*/deleted_*';
COMMENT ON COLUMN public.sys_user_role_mapping.user_id IS '用户 ID';
COMMENT ON COLUMN public.sys_user_role_mapping.role_id IS '角色 ID';
COMMENT ON COLUMN public.sys_user_role_mapping.tenant_id IS '租户 ID';
COMMENT ON COLUMN public.sys_user_role_mapping.created_by IS '授予人（创建人），由应用层/ORM 写入';
COMMENT ON COLUMN public.sys_user_role_mapping.created_at IS '授予时间（创建时间）';


-- public.sys_user_group 定义

-- Drop table

-- DROP TABLE public.sys_user_group;

CREATE TABLE public.sys_user_group
(
    id            int8                                                   NOT NULL,
    status        int2         DEFAULT 1                                 NOT NULL,
    "name"        varchar(256)                                           NOT NULL,
    code          varchar(64)                                            NOT NULL,
    remark        varchar(512)                                           NULL,
    created_by    int8                                                   NOT NULL,
    created_at    timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    updated_by    int8                                                   NOT NULL,
    updated_at    timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    deleted_at    timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    tenant_id     varchar(16)                                            NOT NULL,
    owner_user_id int8                                                   NULL,
    CONSTRAINT sys_user_group_pkey PRIMARY KEY (id),
    CONSTRAINT sys_user_group_status_chk CHECK (status IN (0, 1))
);
CREATE UNIQUE INDEX sys_user_group_tenant_code_un ON public.sys_user_group USING btree (tenant_id, code) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX sys_user_group_tenant_name_un ON public.sys_user_group USING btree (tenant_id, name) WHERE deleted_at IS NULL;
COMMENT ON TABLE public.sys_user_group IS '用户组表 [@default_sort: created_at DESC @pk: id @page: 20/400]';

-- Column comments

COMMENT ON COLUMN public.sys_user_group.id IS '用户组 ID [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_user_group.status IS '数据状态，0：禁用、1：启用 [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_user_group."name" IS '组名 [@dynamic: fuzzy, exact @sortable @selectable]';
COMMENT ON COLUMN public.sys_user_group.code IS '组编码 [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_user_group.remark IS '备注 [@dynamic: fuzzy @selectable]';
COMMENT ON COLUMN public.sys_user_group.created_by IS '创建人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_user_group.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.sys_user_group.updated_by IS '更新人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_user_group.updated_at IS '更新时间 [@dynamic: range @sortable]';
COMMENT ON COLUMN public.sys_user_group.deleted_at IS '删除时间 [@hidden]';
COMMENT ON COLUMN public.sys_user_group.tenant_id IS '租户 ID [@dynamic: exact @selectable]';
COMMENT ON COLUMN public.sys_user_group.owner_user_id IS '组长/归属用户 [@dynamic: exact, in]';


-- public.sys_user_group_mapping 定义

-- Drop table

-- DROP TABLE public.sys_user_group_mapping;

CREATE TABLE public.sys_user_group_mapping
(
    group_id   int8                                   NOT NULL,
    user_id    int8                                   NOT NULL,
    tenant_id  varchar(16)                            NOT NULL,
    created_by int8                                   NOT NULL,
    created_at timestamp(0) DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT sys_user_group_mapping_pk PRIMARY KEY (group_id, user_id)
);
CREATE INDEX idx_sugm_tenant ON public.sys_user_group_mapping USING btree (tenant_id);
CREATE INDEX idx_sugm_user_id ON public.sys_user_group_mapping USING btree (user_id);

-- Column comments

COMMENT ON TABLE public.sys_user_group_mapping IS '用户组成员映射表。映射行无可变业务字段，移除成员走物理删除，因此仅保留 created_by/created_at 最小审计字段，不含 updated_*/deleted_*';
COMMENT ON COLUMN public.sys_user_group_mapping.group_id IS '用户组 ID';
COMMENT ON COLUMN public.sys_user_group_mapping.user_id IS '用户 ID';
COMMENT ON COLUMN public.sys_user_group_mapping.tenant_id IS '租户 ID';
COMMENT ON COLUMN public.sys_user_group_mapping.created_by IS '添加人（创建人），由应用层/ORM 写入';
COMMENT ON COLUMN public.sys_user_group_mapping.created_at IS '添加时间（创建时间）';


-- public.sys_dict_type 定义

-- Drop table

-- DROP TABLE public.sys_dict_type;

CREATE TABLE public.sys_dict_type
(
    id         int8                                                   NOT NULL,
    status     int2         DEFAULT 1                                 NOT NULL,
    "name"     varchar(256)                                           NOT NULL,
    code       varchar(64)                                            NOT NULL,
    remark     varchar(512)                                           NULL,
    created_by int8                                                   NOT NULL,
    created_at timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    updated_by int8                                                   NOT NULL,
    updated_at timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    deleted_at timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    tenant_id  varchar(16)                                            NOT NULL,
    CONSTRAINT sys_dict_type_pkey PRIMARY KEY (id),
    CONSTRAINT sys_dict_type_status_chk CHECK (status IN (0, 1))
);
CREATE UNIQUE INDEX sys_dict_type_tenant_code_un ON public.sys_dict_type USING btree (tenant_id, code) WHERE deleted_at IS NULL;
COMMENT ON TABLE public.sys_dict_type IS '字典类型表 [@default_sort: created_at DESC @pk: id @page: 20/400]';

-- Column comments

COMMENT ON COLUMN public.sys_dict_type.id IS '字典类型 ID [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_dict_type.status IS '数据状态，0：禁用、1：启用 [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_dict_type."name" IS '字典类型名 [@dynamic: fuzzy, exact @sortable @selectable]';
COMMENT ON COLUMN public.sys_dict_type.code IS '字典类型编码 [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_dict_type.remark IS '备注 [@dynamic: fuzzy @selectable]';
COMMENT ON COLUMN public.sys_dict_type.created_by IS '创建人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_dict_type.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.sys_dict_type.updated_by IS '更新人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_dict_type.updated_at IS '更新时间 [@dynamic: range @sortable]';
COMMENT ON COLUMN public.sys_dict_type.deleted_at IS '删除时间 [@hidden]';
COMMENT ON COLUMN public.sys_dict_type.tenant_id IS '租户 ID [@dynamic: exact @selectable]';


-- public.sys_dict_data 定义

-- Drop table

-- DROP TABLE public.sys_dict_data;

CREATE TABLE public.sys_dict_data
(
    id           int8                                                   NOT NULL,
    status       int2         DEFAULT 1                                 NOT NULL,
    dict_type_id int8                                                   NOT NULL,
    label        varchar(256)                                           NOT NULL,
    value        varchar(256)                                           NOT NULL,
    value_type   varchar(32)  DEFAULT 'string'                          NOT NULL,
    sort_order   int4         DEFAULT 0                                 NOT NULL,
    remark       varchar(512)                                           NULL,
    created_by   int8                                                   NOT NULL,
    created_at   timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    updated_by   int8                                                   NOT NULL,
    updated_at   timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    deleted_at   timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    tenant_id    varchar(16)                                            NOT NULL,
    CONSTRAINT sys_dict_data_pkey PRIMARY KEY (id),
    CONSTRAINT sys_dict_data_status_chk CHECK (status IN (0, 1))
);
CREATE UNIQUE INDEX sys_dict_data_type_value_un ON public.sys_dict_data USING btree (tenant_id, dict_type_id, value) WHERE deleted_at IS NULL;
COMMENT ON TABLE public.sys_dict_data IS '字典数据表 [@default_sort: created_at DESC @pk: id @page: 20/400]';

-- Column comments

COMMENT ON COLUMN public.sys_dict_data.id IS '字典数据 ID [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_dict_data.status IS '数据状态，0：禁用、1：启用 [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_dict_data.dict_type_id IS '字典类型 ID [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_dict_data.label IS '字典标签 [@dynamic: fuzzy, exact @sortable @selectable]';
COMMENT ON COLUMN public.sys_dict_data.value IS '字典值 [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_dict_data.value_type IS '值类型：string/integer/boolean/float/json，系统获取值时根据此类型做预处理 [@dynamic: exact @selectable]';
COMMENT ON COLUMN public.sys_dict_data.sort_order IS '排序号 [@dynamic: exact, range @sortable]';
COMMENT ON COLUMN public.sys_dict_data.remark IS '备注 [@dynamic: fuzzy @selectable]';
COMMENT ON COLUMN public.sys_dict_data.created_by IS '创建人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_dict_data.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.sys_dict_data.updated_by IS '更新人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_dict_data.updated_at IS '更新时间 [@dynamic: range @sortable]';
COMMENT ON COLUMN public.sys_dict_data.deleted_at IS '删除时间 [@hidden]';
COMMENT ON COLUMN public.sys_dict_data.tenant_id IS '租户 ID [@dynamic: exact @selectable]';


-- 1a. sys_menu — 菜单/权限树
-- menu_type: 1-目录 2-菜单 3-按钮（操作权限点）
CREATE TABLE public.sys_menu
(
    id              int8                                                   NOT NULL,
    status          int2         DEFAULT 1                                 NOT NULL,
    "name"          varchar(64)                                            NOT NULL,
    permission_code varchar(128)                                           NOT NULL,
    parent_id       int8                                                   NULL,
    menu_type       int2         DEFAULT 1                                 NOT NULL,
    icon            varchar(128)                                           NULL,
    route_path      varchar(256)                                           NULL,
    component       varchar(256)                                           NULL,
    permission_expr varchar(256)                                           NULL,
    sort_order      int4         DEFAULT 0                                 NOT NULL,
    remark          varchar(512)                                           NULL,
    created_by      int8                                                   NOT NULL,
    created_at      timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    updated_by      int8                                                   NOT NULL,
    updated_at      timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    deleted_at      timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    tenant_id       varchar(16)                                            NOT NULL,
    CONSTRAINT sys_menu_pkey PRIMARY KEY (id),
    CONSTRAINT sys_menu_status_chk CHECK (status IN (0, 1)),
    CONSTRAINT sys_menu_type_chk CHECK (menu_type BETWEEN 1 AND 3)
);
CREATE UNIQUE INDEX sys_menu_tenant_code_un ON public.sys_menu USING btree (tenant_id, permission_code) WHERE deleted_at IS NULL;
COMMENT ON TABLE public.sys_menu IS '菜单/权限表，定义系统功能菜单和操作权限的树形结构，通过 sys_role_menu 与角色关联 [@default_sort: sort_order ASC @pk: id @page: 20/200]';

COMMENT ON COLUMN public.sys_menu.id IS '菜单 ID [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_menu.status IS '数据状态，0：禁用、1：启用 [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_menu."name" IS '菜单/权限名称 [@dynamic: fuzzy, exact @sortable @selectable]';
COMMENT ON COLUMN public.sys_menu.permission_code IS '权限编码（租户内唯一），应用层通过此编码匹配权限，命名如 sys:user:create、sys:user:delete [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_menu.parent_id IS '父级菜单 ID，NULL 为根菜单/顶级权限分组 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_menu.menu_type IS '菜单类型：1-目录 2-菜单 3-按钮（操作权限点） [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_menu.icon IS '菜单图标';
COMMENT ON COLUMN public.sys_menu.route_path IS '前端路由路径';
COMMENT ON COLUMN public.sys_menu.component IS '前端组件路径';
COMMENT ON COLUMN public.sys_menu.permission_expr IS '权限表达式，应用层 SPEL 匹配用';
COMMENT ON COLUMN public.sys_menu.sort_order IS '排序号 [@dynamic: exact, range @sortable]';
COMMENT ON COLUMN public.sys_menu.remark IS '备注 [@dynamic: fuzzy @selectable]';
COMMENT ON COLUMN public.sys_menu.created_by IS '创建人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_menu.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.sys_menu.updated_by IS '更新人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_menu.updated_at IS '更新时间 [@dynamic: range @sortable]';
COMMENT ON COLUMN public.sys_menu.deleted_at IS '删除时间 [@dynamic: is_null, not_null]';
COMMENT ON COLUMN public.sys_menu.tenant_id IS '租户 ID [@dynamic: exact @selectable]';

-- 1b. sys_role_menu — 角色-菜单映射
--     映射行无可变业务字段，解除授权走物理删除，
--     因此仅保留 created_by/created_at 最小审计字段（谁在何时授权），不含 updated_*/deleted_*。
CREATE TABLE public.sys_role_menu
(
    role_id    int8                                   NOT NULL,
    menu_id    int8                                   NOT NULL,
    tenant_id  varchar(16)                            NOT NULL,
    created_by int8                                   NOT NULL,
    created_at timestamp(0) DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT sys_role_menu_pkey PRIMARY KEY (role_id, menu_id)
);
CREATE INDEX idx_srm_tenant ON public.sys_role_menu USING btree (tenant_id);
CREATE INDEX idx_srm_menu_id ON public.sys_role_menu USING btree (menu_id);
COMMENT ON TABLE public.sys_role_menu IS '角色-菜单/权限映射表，多对多关联角色与菜单权限点。映射行无可变业务字段，解除授权走物理删除，因此仅保留 created_by/created_at 最小审计字段，不含 updated_*/deleted_*';

COMMENT ON COLUMN public.sys_role_menu.role_id IS '角色 ID，关联 sys_role.id';
COMMENT ON COLUMN public.sys_role_menu.menu_id IS '菜单/权限 ID，关联 sys_menu.id';
COMMENT ON COLUMN public.sys_role_menu.tenant_id IS '租户 ID';
COMMENT ON COLUMN public.sys_role_menu.created_by IS '授权人（创建人），由应用层/ORM 写入';
COMMENT ON COLUMN public.sys_role_menu.created_at IS '授权时间（创建时间）';


-- ============================================================================
-- 2. 审计日志
--    种子数据的"审计员"角色需要真实数据支撑，新增登录日志和操作日志表。
--    日志表为追加写入（append-only），永不更新，因此省略 updated_by/updated_at/deleted_at。
--    日志量较大，使用 bigserial 自增主键。
-- ============================================================================

-- 2a. sys_login_log — 登录日志
CREATE TABLE public.sys_login_log
(
    id             bigserial                              NOT NULL,
    user_id        int8                                   NOT NULL,
    username       varchar(256)                           NOT NULL,
    tenant_id      varchar(16)                            NOT NULL,
    ip_address     varchar(64)                            NULL,
    user_agent     varchar(512)                           NULL,
    login_type     varchar(32)  DEFAULT 'password'        NOT NULL,
    is_success     boolean      DEFAULT true              NOT NULL,
    failure_reason varchar(256)                           NULL,
    login_at       timestamp(0) DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_by     int8                                   NOT NULL,
    created_at     timestamp(0) DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT sys_login_log_pkey PRIMARY KEY (id)
);
CREATE INDEX idx_login_log_tenant_user ON public.sys_login_log USING btree (tenant_id, user_id);
CREATE INDEX idx_login_log_tenant_time ON public.sys_login_log USING btree (tenant_id, login_at DESC);
COMMENT ON TABLE public.sys_login_log IS '登录日志表，记录用户登录尝试（含失败记录），追加写入不可变更 [@default_sort: login_at DESC @pk: id @page: 20/200]';

COMMENT ON COLUMN public.sys_login_log.id IS '日志 ID，自增序列 [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_login_log.user_id IS '用户 ID [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_login_log.username IS '用户名（冗余，便于快速查看） [@dynamic: fuzzy, exact @sortable @selectable]';
COMMENT ON COLUMN public.sys_login_log.tenant_id IS '租户 ID [@dynamic: exact @selectable]';
COMMENT ON COLUMN public.sys_login_log.ip_address IS '登录 IP 地址 [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_login_log.user_agent IS '浏览器/客户端 User-Agent';
COMMENT ON COLUMN public.sys_login_log.login_type IS '登录方式：password-密码登录 sms-短信验证码 oauth-第三方授权 refresh_token-刷新令牌 [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_login_log.is_success IS '是否登录成功 [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_login_log.failure_reason IS '失败原因：如密码错误、账号已禁用、租户已过期、验证码错误 [@dynamic: fuzzy @selectable]';
COMMENT ON COLUMN public.sys_login_log.login_at IS '登录时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.sys_login_log.created_by IS '创建人/操作用户 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_login_log.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';

-- 2b. sys_operation_log — 操作日志
CREATE TABLE public.sys_operation_log
(
    id             bigserial                              NOT NULL,
    user_id        int8                                   NOT NULL,
    username       varchar(256)                           NOT NULL,
    tenant_id      varchar(16)                            NOT NULL,
    operation_type varchar(64)                            NOT NULL,
    target_table   varchar(64)                            NULL,
    target_id      varchar(64)                            NULL,
    old_value      jsonb                                  NULL,
    new_value      jsonb                                  NULL,
    ip_address     varchar(64)                            NULL,
    user_agent     varchar(512)                           NULL,
    api_path       varchar(512)                           NULL,
    http_method    varchar(16)                            NULL,
    duration_ms    int4                                   NULL,
    result_code    varchar(32)                            NULL,
    result_msg     varchar(512)                           NULL,
    request_id     varchar(64)                            NULL,
    operated_at    timestamp(0) DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_by     int8                                   NOT NULL,
    created_at     timestamp(0) DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT sys_operation_log_pkey PRIMARY KEY (id)
);
CREATE INDEX idx_operation_log_tenant_user ON public.sys_operation_log USING btree (tenant_id, user_id);
CREATE INDEX idx_operation_log_tenant_time ON public.sys_operation_log USING btree (tenant_id, operated_at DESC);
CREATE INDEX idx_operation_log_type ON public.sys_operation_log USING btree (tenant_id, operation_type);
COMMENT ON TABLE public.sys_operation_log IS '操作日志表，记录用户对系统数据的操作行为，追加写入不可变更 [@default_sort: operated_at DESC @pk: id @page: 20/200]';

COMMENT ON COLUMN public.sys_operation_log.id IS '日志 ID，自增序列 [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_operation_log.user_id IS '操作用户 ID [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_operation_log.username IS '用户名（冗余） [@dynamic: fuzzy, exact @sortable @selectable]';
COMMENT ON COLUMN public.sys_operation_log.tenant_id IS '租户 ID [@dynamic: exact @selectable]';
COMMENT ON COLUMN public.sys_operation_log.operation_type IS '操作类型：CREATE/UPDATE/DELETE/LOGIN/EXPORT/IMPORT/BATCH_DELETE 等 [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_operation_log.target_table IS '操作目标表名 [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_operation_log.target_id IS '操作目标记录 ID [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_operation_log.old_value IS '操作前数据（jsonb，写入时即校验 JSON 合法性，可索引）';
COMMENT ON COLUMN public.sys_operation_log.new_value IS '操作后数据（jsonb，可索引）';
COMMENT ON COLUMN public.sys_operation_log.ip_address IS '请求 IP 地址 [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_operation_log.user_agent IS '浏览器/客户端 User-Agent';
COMMENT ON COLUMN public.sys_operation_log.api_path IS 'API 路径';
COMMENT ON COLUMN public.sys_operation_log.http_method IS 'HTTP 方法：GET/POST/PUT/DELETE/PATCH [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_operation_log.duration_ms IS '请求耗时（毫秒） [@dynamic: exact, range @sortable]';
COMMENT ON COLUMN public.sys_operation_log.result_code IS '结果码：200/400/403/404/500 等 [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_operation_log.result_msg IS '结果消息 [@dynamic: fuzzy @selectable]';
COMMENT ON COLUMN public.sys_operation_log.request_id IS '请求追踪 ID，用于关联同一请求的多个操作 [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_operation_log.operated_at IS '操作时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.sys_operation_log.created_by IS '创建人/操作用户 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_operation_log.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';


-- ============================================================================
-- 3. 会话管理
--    存储访问令牌和刷新令牌的哈希，支持服务端会话撤销。
--    令牌字段仅存哈希值，不存明文令牌，降低泄露风险。
-- ============================================================================

-- sys_session — 用户会话/令牌
CREATE TABLE public.sys_session
(
    id                 int8                                   NOT NULL,
    status             int2         DEFAULT 1                 NOT NULL,
    user_id            int8                                   NOT NULL,
    tenant_id          varchar(16)                            NOT NULL,
    token_hash         varchar(128)                           NOT NULL,
    refresh_token_hash varchar(128)                           NULL,
    expires_at         timestamp(0)                           NOT NULL,
    refresh_expires_at timestamp(0)                           NULL,
    last_activity_at   timestamp(0)                           NULL,
    device_info        varchar(512)                           NULL,
    ip_address         varchar(64)                            NULL,
    is_revoked         boolean      DEFAULT false             NOT NULL,
    created_by         int8                                   NOT NULL,
    created_at         timestamp(0) DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by         int8                                   NOT NULL,
    updated_at         timestamp(0) DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT sys_session_pkey PRIMARY KEY (id),
    CONSTRAINT sys_session_status_chk CHECK (status IN (0, 1))
);
CREATE UNIQUE INDEX sys_session_token_hash_un ON public.sys_session USING btree (token_hash);
CREATE UNIQUE INDEX sys_session_refresh_token_hash_un ON public.sys_session USING btree (refresh_token_hash) WHERE refresh_token_hash IS NOT NULL;
CREATE INDEX idx_session_tenant_user ON public.sys_session USING btree (tenant_id, user_id);
COMMENT ON TABLE public.sys_session IS '用户会话/令牌表，管理登录访问令牌和刷新令牌，支持服务端主动撤销 [@default_sort: created_at DESC @pk: id @page: 20/200]';

COMMENT ON COLUMN public.sys_session.id IS '会话 ID [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_session.status IS '数据状态，0：禁用、1：启用 [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_session.user_id IS '用户 ID [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_session.tenant_id IS '租户 ID [@dynamic: exact @selectable]';
COMMENT ON COLUMN public.sys_session.token_hash IS '访问令牌哈希（SHA-256），用于查找和验证令牌，不存明文 [@hidden]';
COMMENT ON COLUMN public.sys_session.refresh_token_hash IS '刷新令牌哈希，用于令牌刷新轮换 [@hidden]';
COMMENT ON COLUMN public.sys_session.expires_at IS '访问令牌过期时间 [@dynamic: exact, range @sortable]';
COMMENT ON COLUMN public.sys_session.refresh_expires_at IS '刷新令牌过期时间 [@dynamic: range, is_null, not_null]';
COMMENT ON COLUMN public.sys_session.last_activity_at IS '最后活跃时间，用于检测僵尸会话 [@dynamic: range, is_null, not_null @sortable]';
COMMENT ON COLUMN public.sys_session.device_info IS '设备信息：操作系统、浏览器、设备型号等';
COMMENT ON COLUMN public.sys_session.ip_address IS '登录时 IP 地址 [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_session.is_revoked IS '是否已主动撤销：true 后即使令牌未过期也不可用 [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_session.created_by IS '创建人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_session.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.sys_session.updated_by IS '更新人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_session.updated_at IS '更新时间 [@dynamic: range @sortable]';


-- ============================================================================
-- 4. 系统全局配置
--    全局 key-value 配置，不绑定租户，无 RLS。
--    由平台超级管理员维护，应用层启动时读取。
-- ============================================================================

-- sys_config — 系统全局配置
CREATE TABLE public.sys_config
(
    id         int8                                                   NOT NULL,
    status     int2         DEFAULT 1                                 NOT NULL,
    "name"     varchar(128)                                           NOT NULL,
    config_key varchar(128)                                           NOT NULL,
    value      text                                                   NULL,
    value_type varchar(32)  DEFAULT 'string'                          NOT NULL,
    remark     varchar(512)                                           NULL,
    created_by int8                                                   NOT NULL,
    created_at timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    updated_by int8                                                   NOT NULL,
    updated_at timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    deleted_at timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    CONSTRAINT sys_config_pkey PRIMARY KEY (id),
    CONSTRAINT sys_config_status_chk CHECK (status IN (0, 1))
);
CREATE UNIQUE INDEX sys_config_key_un ON public.sys_config USING btree (config_key) WHERE deleted_at IS NULL;
COMMENT ON TABLE public.sys_config IS '系统全局配置表，存储平台级系统参数，不绑定租户，所有租户共享 [@default_sort: created_at DESC @pk: id @page: 20/200]';

COMMENT ON COLUMN public.sys_config.id IS '配置 ID [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_config.status IS '数据状态，0：禁用、1：启用 [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_config."name" IS '配置名称 [@dynamic: fuzzy, exact @sortable @selectable]';
COMMENT ON COLUMN public.sys_config.config_key IS '配置键（唯一），如 smtp.host、jwt.secret、session.timeout [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_config.value IS '配置值';
COMMENT ON COLUMN public.sys_config.value_type IS '值类型：string/integer/boolean/float/json [@dynamic: exact @selectable]';
COMMENT ON COLUMN public.sys_config.remark IS '备注 [@dynamic: fuzzy @selectable]';
COMMENT ON COLUMN public.sys_config.created_by IS '创建人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_config.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.sys_config.updated_by IS '更新人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_config.updated_at IS '更新时间 [@dynamic: range @sortable]';
COMMENT ON COLUMN public.sys_config.deleted_at IS '删除时间 [@dynamic: is_null, not_null]';


-- ============================================================================
-- 5. 租户配置
--    每个租户的自定义配置参数，有 RLS 租户隔离。
--    用于存储租户级别的个性化设置，覆盖全局配置的默认值。
-- ============================================================================

-- sys_tenant_config — 租户配置
CREATE TABLE public.sys_tenant_config
(
    id         int8                                                   NOT NULL,
    status     int2         DEFAULT 1                                 NOT NULL,
    "name"     varchar(128)                                           NOT NULL,
    config_key varchar(128)                                           NOT NULL,
    value      text                                                   NULL,
    value_type varchar(32)  DEFAULT 'string'                          NOT NULL,
    remark     varchar(512)                                           NULL,
    created_by int8                                                   NOT NULL,
    created_at timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    updated_by int8                                                   NOT NULL,
    updated_at timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    deleted_at timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    tenant_id  varchar(16)                                            NOT NULL,
    CONSTRAINT sys_tenant_config_pkey PRIMARY KEY (id),
    CONSTRAINT sys_tenant_config_status_chk CHECK (status IN (0, 1))
);
CREATE UNIQUE INDEX sys_tenant_config_key_un ON public.sys_tenant_config USING btree (tenant_id, config_key) WHERE deleted_at IS NULL;
COMMENT ON TABLE public.sys_tenant_config IS '租户配置表，存储各租户的自定义配置参数，覆盖系统全局配置的默认值 [@default_sort: created_at DESC @pk: id @page: 20/200]';

COMMENT ON COLUMN public.sys_tenant_config.id IS '配置 ID [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_tenant_config.status IS '数据状态，0：禁用、1：启用 [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_tenant_config."name" IS '配置名称 [@dynamic: fuzzy, exact @sortable @selectable]';
COMMENT ON COLUMN public.sys_tenant_config.config_key IS '配置键（租户内唯一） [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_tenant_config.value IS '配置值';
COMMENT ON COLUMN public.sys_tenant_config.value_type IS '值类型：string/integer/boolean/float/json [@dynamic: exact @selectable]';
COMMENT ON COLUMN public.sys_tenant_config.remark IS '备注 [@dynamic: fuzzy @selectable]';
COMMENT ON COLUMN public.sys_tenant_config.created_by IS '创建人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_tenant_config.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.sys_tenant_config.updated_by IS '更新人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_tenant_config.updated_at IS '更新时间 [@dynamic: range @sortable]';
COMMENT ON COLUMN public.sys_tenant_config.deleted_at IS '删除时间 [@dynamic: is_null, not_null]';
COMMENT ON COLUMN public.sys_tenant_config.tenant_id IS '租户 ID [@dynamic: exact @selectable]';


-- ============================================================================
-- 6. 功能特性
--    租户级别的功能开关，控制哪些功能对特定租户开放。
--    支持灰度发布、按租户控制功能权限（如导出、SSO、API 访问等）。
-- ============================================================================

-- sys_feature_flag — 功能特性
CREATE TABLE public.sys_feature_flag
(
    id          int8                                                   NOT NULL,
    status      int2         DEFAULT 1                                 NOT NULL,
    "name"      varchar(128)                                           NOT NULL,
    flag_key    varchar(128)                                           NOT NULL,
    description varchar(512)                                           NULL,
    is_enabled  boolean      DEFAULT false                             NOT NULL,
    remark      varchar(512)                                           NULL,
    created_by  int8                                                   NOT NULL,
    created_at  timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    updated_by  int8                                                   NOT NULL,
    updated_at  timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    deleted_at  timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    tenant_id   varchar(16)                                            NOT NULL,
    CONSTRAINT sys_feature_flag_pkey PRIMARY KEY (id),
    CONSTRAINT sys_feature_flag_status_chk CHECK (status IN (0, 1))
);
CREATE UNIQUE INDEX sys_feature_flag_tenant_key_un ON public.sys_feature_flag USING btree (tenant_id, flag_key) WHERE deleted_at IS NULL;
COMMENT ON TABLE public.sys_feature_flag IS '功能特性表，控制各租户的功能开关，支持灰度发布和按租户授权 [@default_sort: created_at DESC @pk: id @page: 20/200]';

COMMENT ON COLUMN public.sys_feature_flag.id IS '特性 ID [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_feature_flag.status IS '数据状态，0：禁用、1：启用 [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_feature_flag."name" IS '特性名称 [@dynamic: fuzzy, exact @sortable @selectable]';
COMMENT ON COLUMN public.sys_feature_flag.flag_key IS '特性键（租户内唯一），如 export_enabled、sso_enabled、api_access、audit_log [@dynamic: exact, prefix @selectable]';
COMMENT ON COLUMN public.sys_feature_flag.description IS '特性描述，说明该功能的作用和使用场景 [@dynamic: fuzzy @selectable]';
COMMENT ON COLUMN public.sys_feature_flag.is_enabled IS '是否启用：true-开启功能 false-关闭功能 [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_feature_flag.remark IS '备注 [@dynamic: fuzzy @selectable]';
COMMENT ON COLUMN public.sys_feature_flag.created_by IS '创建人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_feature_flag.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.sys_feature_flag.updated_by IS '更新人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_feature_flag.updated_at IS '更新时间 [@dynamic: range @sortable]';
COMMENT ON COLUMN public.sys_feature_flag.deleted_at IS '删除时间 [@dynamic: is_null, not_null]';
COMMENT ON COLUMN public.sys_feature_flag.tenant_id IS '租户 ID [@dynamic: exact @selectable]';


-- ============================================================================
-- 7. 国际适配 — 通用翻译表
--    为 sys_menu.name、sys_dict_data.label、sys_dept.name 等可翻译字段
--    提供多语言支持。一张表覆盖所有实体，通过 (table_name, row_id, column_name, locale)
--    唯一确定一条翻译记录。
-- ============================================================================

-- sys_translation — 通用翻译表
-- locale 格式：BCP-47 语言标记，如 zh-CN、en-US、ja-JP、ko-KR
CREATE TABLE public.sys_translation
(
    id          int8                                                   NOT NULL,
    status      int2         DEFAULT 1                                 NOT NULL,
    table_name  varchar(64)                                            NOT NULL,
    row_id      int8                                                   NOT NULL,
    column_name varchar(64)                                            NOT NULL,
    locale      varchar(10)                                            NOT NULL,
    value       text                                                   NOT NULL,
    remark      varchar(512)                                           NULL,
    created_by  int8                                                   NOT NULL,
    created_at  timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    updated_by  int8                                                   NOT NULL,
    updated_at  timestamp(0) DEFAULT CURRENT_TIMESTAMP                 NOT NULL,
    deleted_at  timestamp(0) DEFAULT NULL::timestamp without time zone NULL,
    tenant_id   varchar(16)                                            NOT NULL,
    CONSTRAINT sys_translation_pkey PRIMARY KEY (id),
    CONSTRAINT sys_translation_status_chk CHECK (status IN (0, 1))
);
CREATE UNIQUE INDEX sys_translation_tenant_un ON public.sys_translation USING btree (table_name, row_id, column_name, locale, tenant_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_translation_lookup ON public.sys_translation USING btree (table_name, row_id, column_name, locale) WHERE deleted_at IS NULL AND status = 1;
COMMENT ON TABLE public.sys_translation IS '通用翻译表，为业务表字段提供多语言翻译能力，支持按实体-字段-语言粒度管理 [@default_sort: created_at DESC @pk: id @page: 20/200]';

COMMENT ON COLUMN public.sys_translation.id IS '翻译 ID [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_translation.status IS '数据状态，0：禁用、1：启用（可暂未翻译时禁用，前端回退原始值） [@dynamic: exact, in @sortable @selectable]';
COMMENT ON COLUMN public.sys_translation.table_name IS '来源表名，如 sys_menu、sys_dict_data、sys_dept [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_translation.row_id IS '来源行主键 ID [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_translation.column_name IS '来源列名，如 name、label [@dynamic: exact, in @selectable]';
COMMENT ON COLUMN public.sys_translation.locale IS '语言代码（BCP-47），如 zh-CN、en-US、ja-JP [@dynamic: exact @selectable]';
COMMENT ON COLUMN public.sys_translation.value IS '翻译文本，对应语言的展示值 [@dynamic: fuzzy, exact @sortable @selectable]';
COMMENT ON COLUMN public.sys_translation.remark IS '备注 [@dynamic: fuzzy @selectable]';
COMMENT ON COLUMN public.sys_translation.created_by IS '创建人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_translation.created_at IS '创建时间 [@dynamic: exact, in, range @sortable @selectable]';
COMMENT ON COLUMN public.sys_translation.updated_by IS '更新人 [@dynamic: exact, in]';
COMMENT ON COLUMN public.sys_translation.updated_at IS '更新时间 [@dynamic: range @sortable]';
COMMENT ON COLUMN public.sys_translation.deleted_at IS '删除时间 [@dynamic: is_null, not_null]';
COMMENT ON COLUMN public.sys_translation.tenant_id IS '租户 ID [@dynamic: exact @selectable]';