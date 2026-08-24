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
