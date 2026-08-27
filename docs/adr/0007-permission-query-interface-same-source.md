# 权限查询接口：内外同源 + 传输无关服务层

外部系统是不同进程、不同数据库的服务，其数据以归属字段引用本库的用户/部门/组 ID，需要本体系提供权限机制：操作/功能权限判断、可视范围获取、批量判断（远程往返优化）、用户字段投影（如呼叫中心分机号）。决定：接口本体是**传输无关的 Go 服务层**（根级 `perm/` 包，底层 = SQL 函数 + sqlc 生成代码），HTTP/gRPC 外壳由宿主系统自行包装，本 repo 不交付适配器；所有对外查询与内部 `@scope` 守卫**走同一套库内函数**（`fn_accessible_*`、`fn_can_*`、新查询判断函数），单一事实源、内外判定不分歧。新查询判断函数族进 `sqlcpg/expose.sql`（读侧·外部查询判断，与 rls.sql 读过滤 / operate.sql 写判断三足鼎立）：`fn_check_visible`（带维度选择参数）、`fn_filter_visible_rows`（unnest 批量、返回允许子集）、`fn_has_permission`（功能权限轴，补上该轴库内零判定的空白）；存量单参守卫函数一律不动（ADR-0002 边界不变，维度参数只存在于新家族）。只读暴露的拒绝以 false/空集表达，不是 ErrDenied（错误语义只留给写侧）；`GetScope` 按人/部门/组三粒度返回三态 `{All, IDs}`，全租户（All）绝不展开为全量 ID 列表，紧凑表示留作演进。

## Considered Options

- **为外部单独建读模型/权限投影缓存表**：内外双实现，判定分歧与双维护成本；确有性能隔离需求时再立新 ADR 决策；弃。
- **接口直接绑定 HTTP/gRPC 交付**：传输层锁定，违背可复制定位；弃。
- **给存量守卫函数加维度参数**：破坏 ADR-0002 单参契约与全部调用点；弃。

## Consequences

- 外部查询流量与内部列表查询共用同一批 DB 函数，无性能隔离（接受：一致性优先）。
- 每次调用以 AuthContext{TenantID, UserID} 显式入参，事务内 set_config app.tenant_id（复用 example.Begin 模式），不存在跨进程共享会话。
- sys_user 的批量可见性不单设接口，由 ListVisibleUsers 覆盖（动态 ListSysUser + Scope 强制注入 + SelectFields 投影，敏感列被 @hidden 挡住）；分机号等扩展列本期不加，但业务项目加列重生成后调用方式不变。
- example 演示服务层本地调用（同现有 gen 演示），不做传输适配器。
