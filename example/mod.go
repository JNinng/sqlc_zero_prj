// Package example 是给业务项目抄的接入示范（门面，mod.go）：
// 展示怎么用最少的胶水代码把生成层接起来——
//
//	AuthContext（登录后拿到的租户/用户）
//	  → Begin：开事务并设置 app.tenant_id（RLS 需要）
//	  → 列表查询：解析前端查询条件，注入当前用户，调 List/Count
//	  → 写入：先调权限判断函数，通过才执行写入
//
// 封装范围刻意精简：两张带 @scope 的表（Basic / SysUser）加一张
// 不带的表（SysDictData）覆盖了全部情况，其余表照抄同样的写法。
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

// AuthContext 是登录后从认证信息里拿到的两个值：
// TenantID 写进会话变量 app.tenant_id（RLS 靠它隔离租户）；
// UserID 传给权限过滤函数和判断函数算可见范围。
// 用户有什么角色、能看到什么，全部在数据库里算，应用层不用管。
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

// Q 返回绑定本事务的 sqlc 查询集。命名查询（GetUser、权限判断、写入）
// 都是 *Queries 上的方法，要先 New(db) 再调用——注意和动态查询不同，
// 动态查询（ParseXxx/ListXxx）是顶层函数，db 作为参数显式传入。
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

// RoleScope 只在演示打印时用：显示某个用户有哪些角色、每个角色的
// 数据范围是什么。真正的权限计算都在数据库里做，应用层不靠它判断。
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

// MyRoles 返回当前用户的角色和数据范围（演示打印用）。
// 数据库里的权限过滤函数做的也是同样的查询。
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
// 列表查询的封装套路：先解析前端传来的查询条件，再把当前用户
// 塞进 Scope 字段，最后调 List/Count。Scope 只能由服务端代码设置，
// 前端请求里根本没有这个字段；忘了设置会直接报错（不会退化成
// 看到全部数据）。
// ------------------------------------------------------------

// BasicAPI 是业务模板表 basic 的接口（表配了 @scope，列表按权限过滤）。
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

// SysUserAPI 是用户表的接口（表配了 @scope，列表按权限过滤）。
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
// 对照：没配 @scope 的表。租户内所有人都能看全（只受 RLS 租户
// 隔离），没有 Scope 可以注入。
// ------------------------------------------------------------

// SysDictDataAPI 是字典数据表的接口（表没配 @scope，不做行级过滤）。
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
// 写入前的权限判断：先调数据库里的判断函数，返回 true 才执行写入。
// 两步在同一个事务里，判断不通过就报错，整个事务回滚，不会写进
// 任何数据。角色一撤销，下一次判断立刻不通过。
// ------------------------------------------------------------

// ErrDenied 表示权限判断不通过（业务层一般对应 HTTP 403）。
// 它和 dynq 的 Kind=scope 错误（列表查询忘了注入 Scope）是这套
// 模板里两种权限相关的错误。
type ErrDenied struct {
	Resource string // 操作对象，如 "sys_role" / "basic"
	Action   string // 动作，如 "assign" / "transfer_owner"
	Reason   string // 给人看的拒绝原因
}

func (e *ErrDenied) Error() string {
	return fmt.Sprintf("denied: %s %s: %s", e.Action, e.Resource, e.Reason)
}

// OwnerTriplet 表示一条数据的归属：归属人、归属部门、归属用户组。
// nil 表示没有这个归属（数据库里存 NULL），不会和 ID=0 混淆。
type OwnerTriplet struct {
	UserID   *int64
	DeptID   *int64
	GroupID  *int64
}

// RoleAdminAPI 把角色分配给用户：先调 fn_can_assign_role 判断，
// 通过才写入映射表。tenant_id 自动取会话值，created_by 记操作者。
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
			"operator=%d 分配 role=%d 给 user=%d 被拒（目标部门不符合角色配置，或你看不见目标用户；规则见 fn_can_assign_role）",
			auth.UserID, roleID, targetUserID)}
	}
	return s.Q().AssignUserRole(ctx, gen.AssignUserRoleParams{
		UserID: targetUserID, RoleID: roleID, CreatedBy: auth.UserID,
	})
}

// TransferOwner 修改一条 basic 数据的归属，三步在同一个事务里：
// 先锁行读出它现在的归属，再调 fn_can_transfer_owner 判断
// （这条数据你有权操作 + 新归属的人/部门/组在可见范围内），
// 通过才执行修改；updated_at 由触发器自动刷新。
// 行不存在时也返回 ErrDenied——别的租户的数据在 RLS 下查不到。
func (BasicAPI) TransferOwner(ctx context.Context, s *Session, id int64, to OwnerTriplet) error {
	auth := s.Auth()
	row, err := s.Q().GetBasicForUpdate(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return &ErrDenied{Resource: "basic", Action: "transfer_owner",
			Reason: fmt.Sprintf("行 id=%d 不存在或不在本租户", id)}
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
			"operator=%d 修改行 id=%d 归属被拒（这条数据你无权操作，或新归属的人/部门/组不在你的可见范围内）",
			auth.UserID, id)}
	}
	return s.Q().UpdateBasicOwner(ctx, gen.UpdateBasicOwnerParams{
		OwnerUser: to.UserID, OwnerDept: to.DeptID, OwnerGroup: to.GroupID,
		UpdatedBy: auth.UserID, ID: id,
	})
}
