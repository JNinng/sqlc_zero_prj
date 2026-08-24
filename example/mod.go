// Package example 是消费方接入范式示范（门面，mod.go）：
// 展示业务项目以最少的胶水代码把生成层接入认证上下文——
//
//	AuthContext → RLS 会话注入（事务级 set_config）→ @scope 守卫注入 → Parse/List/Count
//
// 封装范围刻意精简：两个守卫资源（Basic / SysUser）+ 一个无守卫资源
// （SysDictData）覆盖全部形态，其余表按同模式复制即可。
package example

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jninng/sqlc_gen_dynamic/dynq"

	gen "sqlc_zero_prj/sqlcpg/gen"
)

// AuthContext 是认证中间件产出的最小身份事实：
// TenantID 命中 RLS 会话变量 app.tenant_id；UserID 命中守卫函数入参。
// 数据范围推导不在应用层——守卫函数在库内由 UserID 推出（ADR-0002）。
type AuthContext struct {
	TenantID string
	UserID   int64
}

// Session 是绑定了 AuthContext 的事务：app.tenant_id 以事务级
// set_config 注入，事务结束自动回收，连接归还池后不携带上一请求的
// 租户上下文。
type Session struct {
	tx   pgx.Tx
	auth AuthContext
	q    *gen.Queries
}

// Q 返回绑定本事务的 sqlc 查询集。named queries（GetUser/判定/写入等）
// 均为 *Queries 的方法：先 New(db) 实例化再调用，不是包级函数——
// 与动态查询（ParseXxx/ListXxx 顶层函数、显式传 DBTX）是两种生成风格。
func (s *Session) Q() *gen.Queries {
	if s.q == nil {
		s.q = gen.New(s.tx)
	}
	return s.q
}

// Begin 开启事务并注入租户会话变量，fn 内执行查询，返回 error 回滚。
// 所有以 test_u 类普通角色建立的连接都必须走这里（或等价的 set_config）。
func Begin(ctx context.Context, pool *pgxpool.Pool, auth AuthContext, fn func(*Session) error) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, "SELECT set_config('app.tenant_id', $1, true)", auth.TenantID); err != nil {
		return fmt.Errorf("set app.tenant_id: %w", err)
	}
	if err := fn(&Session{tx: tx, auth: auth}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Tx 暴露底层事务；生成代码的 List/Count 接受任意 DBTX（含 pgx.Tx）。
func (s *Session) Tx() pgx.Tx { return s.tx }

// Auth 返回本会话的身份事实。
func (s *Session) Auth() AuthContext { return s.auth }

// RoleScope 是"角色 → 数据范围"叙述链的一环，仅用于演示打印：
// 守卫函数在库内做同样的推导，应用层不依赖它做任何判断。
type RoleScope struct {
	Name      string
	DataScope int16
}

var dataScopeNames = map[int16]string{
	1: "仅本人", 2: "本部门", 3: "本部门及子部门", 4: "指定人",
	5: "指定部门", 6: "用户组", 7: "全租户",
}

// DescribeDataScope 返回 data_scope 数值的业务名（演示打印用）。
func DescribeDataScope(v int16) string {
	if n, ok := dataScopeNames[v]; ok {
		return n
	}
	return fmt.Sprintf("未知(%d)", v)
}

// MyRoles 返回当前用户的有效角色及其 data_scope。
// 演示"全链路"：从映射表与角色表读出推导输入，叙述守卫函数在库内
// 完成的同一段推导。
func (s *Session) MyRoles(ctx context.Context) ([]RoleScope, error) {
	rows, err := s.tx.Query(ctx, `
		SELECT r."name", r.data_scope
		FROM public.sys_role r
		JOIN public.sys_user_role_mapping m ON m.role_id = r.id
		WHERE m.user_id = $1 AND r.status = 1 AND r.deleted_at IS NULL
		ORDER BY r.data_scope, r.id`, s.auth.UserID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []RoleScope
	for rows.Next() {
		var rs RoleScope
		if err := rows.Scan(&rs.Name, &rs.DataScope); err != nil {
			return nil, err
		}
		out = append(out, rs)
	}
	return out, rows.Err()
}

// ------------------------------------------------------------
// 守卫资源封装范式：Parse 之后、调用之前，Scope 只能从服务端
// AuthContext 注入——协议门结构性无法触达该字段（缺省即 fail-closed）。
// ------------------------------------------------------------

// BasicAPI 是业务模板表（带 @scope 三守卫）的资源门面。
type BasicAPI struct{}

func (BasicAPI) List(ctx context.Context, s *Session, q *dynq.Query, opts ...dynq.QueryOption) (dynq.Result[gen.Basic], error) {
	p, err := gen.ParseBasicQuery(q, opts...)
	if err != nil {
		return dynq.Result[gen.Basic]{}, err
	}
	p.Scope = &gen.BasicScope{UserID: s.auth.UserID}
	return gen.ListBasic(ctx, s.tx, p, opts...)
}

func (BasicAPI) Count(ctx context.Context, s *Session, q *dynq.Query, opts ...dynq.QueryOption) (int64, error) {
	p, err := gen.ParseBasicQuery(q, opts...)
	if err != nil {
		return 0, err
	}
	p.Scope = &gen.BasicScope{UserID: s.auth.UserID}
	return gen.CountBasic(ctx, s.tx, p, opts...)
}

// QuerySchema 返回前端可用的查询能力描述（过滤/排序/投影白名单）。
func (BasicAPI) QuerySchema(opts ...dynq.QueryOption) dynq.ResourceSchema {
	return gen.BasicQuerySchema(opts...)
}

// SysUserAPI 是用户表（带 @scope 三守卫）的资源门面。
type SysUserAPI struct{}

func (SysUserAPI) List(ctx context.Context, s *Session, q *dynq.Query, opts ...dynq.QueryOption) (dynq.Result[gen.SysUser], error) {
	p, err := gen.ParseSysUserQuery(q, opts...)
	if err != nil {
		return dynq.Result[gen.SysUser]{}, err
	}
	p.Scope = &gen.SysUserScope{UserID: s.auth.UserID}
	return gen.ListSysUser(ctx, s.tx, p, opts...)
}

func (SysUserAPI) Count(ctx context.Context, s *Session, q *dynq.Query, opts ...dynq.QueryOption) (int64, error) {
	p, err := gen.ParseSysUserQuery(q, opts...)
	if err != nil {
		return 0, err
	}
	p.Scope = &gen.SysUserScope{UserID: s.auth.UserID}
	return gen.CountSysUser(ctx, s.tx, p, opts...)
}

// ------------------------------------------------------------
// 无守卫资源对照范式：租户内公共数据，仅受 RLS 租户隔离，
// 无需（也无法）注入 Scope——与守卫资源形成形态对照。
// ------------------------------------------------------------

// SysDictDataAPI 是字典数据表（无 @scope）的资源门面。
type SysDictDataAPI struct{}

func (SysDictDataAPI) List(ctx context.Context, s *Session, q *dynq.Query, opts ...dynq.QueryOption) (dynq.Result[gen.SysDictDatum], error) {
	p, err := gen.ParseSysDictDataQuery(q, opts...)
	if err != nil {
		return dynq.Result[gen.SysDictDatum]{}, err
	}
	return gen.ListSysDictData(ctx, s.tx, p, opts...)
}

func (SysDictDataAPI) Count(ctx context.Context, s *Session, q *dynq.Query, opts ...dynq.QueryOption) (int64, error) {
	p, err := gen.ParseSysDictDataQuery(q, opts...)
	if err != nil {
		return 0, err
	}
	return gen.CountSysDictData(ctx, s.tx, p, opts...)
}

// ------------------------------------------------------------
// 操作权限（写侧，ADR-0006）：判定函数 + 同事务先检后写。
// 判定与写入共用一个事务：判定为假 → ErrDenied → 调用方回滚，
// 绝不落库；撤销角色对读写判定同时即时生效（共享守卫推导）。
// ------------------------------------------------------------

// ErrDenied 是操作权限判定拒绝的类型化错误（HTTP 层映射 403），
// 与 dynq 的 Kind=scope（读侧 fail-closed）并列为模板的两种权限错误形态。
type ErrDenied struct {
	Resource string // 资源标识，如 "sys_role" / "basic"
	Action   string // 动作，如 "assign" / "transfer_owner"
	Reason   string // 人读的拒绝原因（哪个判定、为什么不放行）
}

func (e *ErrDenied) Error() string {
	return fmt.Sprintf("denied: %s %s: %s", e.Action, e.Resource, e.Reason)
}

// OwnerTriplet 是归属三元组的可空表达（指针 nil = 无该维归属，
// NULL 语义直达判定函数，不经零值转换）。
type OwnerTriplet struct {
	UserID   *int64
	DeptID   *int64
	GroupID  *int64
}

// RoleAdminAPI 角色分配：fn_can_assign_role 判定（sys_role_allowed_dept
// 成文规则的执行体）通过才落 sys_user_role_mapping；tenant_id 取会话
// 事实（current_setting），created_by 取操作者。
type RoleAdminAPI struct{}

func (RoleAdminAPI) Assign(ctx context.Context, s *Session, roleID, targetUserID int64) error {
	auth := s.Auth()
	ok, err := s.Q().CanAssignRole(ctx, gen.CanAssignRoleParams{
		Operator: auth.UserID, Role: roleID, Target: targetUserID,
	})
	if err != nil {
		return err
	}
	if !ok {
		return &ErrDenied{Resource: "sys_role", Action: "assign", Reason: fmt.Sprintf(
			"operator=%d 分配 role=%d 给 user=%d 被拒（映射部门集/子树约束/数据范围覆盖，见 fn_can_assign_role 注释）",
			auth.UserID, roleID, targetUserID)}
	}
	return s.Q().AssignUserRole(ctx, gen.AssignUserRoleParams{
		UserID: targetUserID, RoleID: roleID, CreatedBy: auth.UserID,
	})
}

// TransferOwner 归属转移：锁行（FOR UPDATE）→ fn_can_transfer_owner
// 双向判定（旧行可达 + 新归属目标可达）→ 通过才 UPDATE；
// updated_at 由 touch 触发器兜底刷新。行不存在/跨租户（RLS 不可见）
// 同样以 ErrDenied 表达——读不到即操作不到。
func (BasicAPI) TransferOwner(ctx context.Context, s *Session, id int64, to OwnerTriplet) error {
	auth := s.Auth()
	row, err := s.Q().GetBasicForUpdate(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return &ErrDenied{Resource: "basic", Action: "transfer_owner",
			Reason: fmt.Sprintf("行 id=%d 不存在或不在本租户（RLS 不可见即不可操作）", id)}
	}
	if err != nil {
		return err
	}
	ok, err := s.Q().CanTransferOwner(ctx, gen.CanTransferOwnerParams{
		Operator: auth.UserID,
		OldUser:  row.OwnerUserID, OldDept: row.OwnerDeptID, OldGroup: row.OwnerUserGroupID,
		NewUser:  to.UserID, NewDept: to.DeptID, NewGroup: to.GroupID,
	})
	if err != nil {
		return err
	}
	if !ok {
		return &ErrDenied{Resource: "basic", Action: "transfer_owner", Reason: fmt.Sprintf(
			"operator=%d 转移行 id=%d 归属被拒（双向校验：旧行可达与新归属目标可达须同时成立）",
			auth.UserID, id)}
	}
	return s.Q().UpdateBasicOwner(ctx, gen.UpdateBasicOwnerParams{
		OwnerUser: to.UserID, OwnerDept: to.DeptID, OwnerGroup: to.GroupID,
		UpdatedBy: auth.UserID, ID: id,
	})
}
