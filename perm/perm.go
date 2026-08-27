// Package perm 是权限查询接口的服务层（接口本体，传输无关）。
//
// 面向不同进程、不同数据库的外部系统：它们的数据以归属字段引用
// 本库的用户/部门/组 ID，需要判断可见性、拉可视范围、批量过滤、
// 查权限码/角色/用户字段。底层与内部 @scope 守卫共用同一套库内
// 推导函数，内外判定不分歧（ADR-0007）；HTTP/gRPC 外壳由宿主系统
// 自行包装，本包不关心传输层。
//
// 约定：
//   - 每次调用显式传入 AuthContext（不存在跨进程共享会话），服务层
//     开事务 set_config app.tenant_id（RLS），事务结束自动回收；
//   - 全部只读；拒绝以 false/空集表达，不是错误（错误只留给系统故障）；
//   - 批量固定操作者、批量目标，只回允许子集（远程往返优化）。
package perm

import (
	"context"
	"fmt"
	"slices"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jninng/sqlc_gen_dynamic/dynq"

	gen "sqlc_zero_prj/sqlcpg/gen"
)

// AuthContext 是外部调用显式传入的身份：TenantID 进会话变量
// app.tenant_id（RLS），UserID 传给库内推导函数算可见范围。
type AuthContext struct {
	TenantID string
	UserID   int64
}

// Dims 是维度选择掩码：1 归属人、2 归属部门、4 归属用户组，按位组合
// 即混合（选中维度 OR 并集）；DimAll 等价 fn_can_operate_row 的全维度。
// 无效值（0 或超出已知位）在库内一律判不可见（fail-closed）。
type Dims int16

const (
	DimUser  Dims = 1
	DimDept  Dims = 2
	DimGroup Dims = 4
	DimAll   Dims = DimUser | DimDept | DimGroup
)

// ScopeSet 是一个维度的三态可见集合：All=true 表示全租户不过滤
// （库内返回 NULL，绝不展开成全量 ID）；All=false 且 IDs 为空数组
// 表示什么都看不见；否则 IDs 是可见 ID 并集。
type ScopeSet struct {
	All bool
	IDs []int64
}

// Visible 判断单个 ID 在本维度是否可见（全租户恒可见）。
func (s ScopeSet) Visible(id int64) bool {
	return s.All || slices.Contains(s.IDs, id)
}

func newScopeSet(ids []int64) ScopeSet {
	if ids == nil { // 库内 NULL：全租户
		return ScopeSet{All: true}
	}
	return ScopeSet{IDs: ids}
}

// Scope 是三个维度的可见集合，GetScope 一次取回。
type Scope struct {
	Users  ScopeSet
	Depts  ScopeSet
	Groups ScopeSet
}

// OwnerTriplet 是一条数据的归属三元组，nil 表示无该归属（库里存
// NULL），与 example.OwnerTriplet 同构。
type OwnerTriplet struct {
	UserID  *int64
	DeptID  *int64
	GroupID *int64
}

// Version 是范围版本（ADR-0008）：缓存有效性 = 两个版本都未变。
// 只用于相等比较，不承诺大小语义。
type Version struct {
	Tenant int64
	User   int64
}

// Service 构造后并发安全，每个方法独立事务。
type Service struct {
	pool *pgxpool.Pool
}

// New 基于 pgx 连接池构建服务。宿主系统在此之上包 HTTP/gRPC。
func New(pool *pgxpool.Pool) *Service { return &Service{pool: pool} }

// withTx 开事务并注入租户会话变量（同 example.Begin 模式），
// fn 返回 error 即回滚。
func (s *Service) withTx(ctx context.Context, auth AuthContext, fn func(q *gen.Queries, tx pgx.Tx) error) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, "SELECT set_config('app.tenant_id', $1, true)", auth.TenantID); err != nil {
		return fmt.Errorf("set app.tenant_id: %w", err)
	}
	if err := fn(gen.New(tx), tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// ------------------------------------------------------------
// 判断类
// ------------------------------------------------------------

// CheckVisible 单点判断：操作者按 dims 指定的维度能否看见/操作一条
// 归属为 t 的数据（读写同权）。拒绝返回 false，不是错误。
func (s *Service) CheckVisible(ctx context.Context, auth AuthContext, dims Dims, t OwnerTriplet) (bool, error) {
	var ok bool
	err := s.withTx(ctx, auth, func(q *gen.Queries, _ pgx.Tx) error {
		var err error
		ok, err = q.CheckVisible(ctx, gen.CheckVisibleParams{
			Operator: auth.UserID, Dims: int16(dims),
			OwnerUser: t.UserID, OwnerDept: t.DeptID, OwnerGroup: t.GroupID,
		})
		return err
	})
	return ok, err
}

// FilterVisibleRows 批量判断：一次传入一组归属三元组（外部系统
// 自己库里的行），返回其中可见的子集，保持传入顺序。
// 固定操作者、批量目标、只回允许子集——远程系统一次往返完成过滤。
// 直接调库内 fn_filter_visible_rows（sqlc 解析不了表函数返回列，
// named query 表达不了，见 queries.sql）。
func (s *Service) FilterVisibleRows(ctx context.Context, auth AuthContext, dims Dims, targets []OwnerTriplet) ([]OwnerTriplet, error) {
	if len(targets) == 0 {
		return nil, nil
	}
	users := make([]*int64, len(targets))
	depts := make([]*int64, len(targets))
	groups := make([]*int64, len(targets))
	for i, t := range targets {
		users[i], depts[i], groups[i] = t.UserID, t.DeptID, t.GroupID
	}
	var visible []OwnerTriplet
	err := s.withTx(ctx, auth, func(_ *gen.Queries, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT owner_user_id, owner_dept_id, owner_user_group_id
			FROM public.fn_filter_visible_rows($1, $2, $3, $4, $5)`,
			auth.UserID, int16(dims), users, depts, groups)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var t OwnerTriplet
			if err := rows.Scan(&t.UserID, &t.DeptID, &t.GroupID); err != nil {
				return err
			}
			visible = append(visible, t)
		}
		return rows.Err()
	})
	return visible, err
}

// HasPermission 判断操作者是否持有某功能权限码（角色→菜单→权限码，
// 与数据范围正交）。不持有返回 false，不是错误。
func (s *Service) HasPermission(ctx context.Context, auth AuthContext, code string) (bool, error) {
	var ok bool
	err := s.withTx(ctx, auth, func(q *gen.Queries, _ pgx.Tx) error {
		var err error
		ok, err = q.HasPermission(ctx, gen.HasPermissionParams{Operator: auth.UserID, Code: code})
		return err
	})
	return ok, err
}

// ------------------------------------------------------------
// 范围与枚举类
// ------------------------------------------------------------

// GetScope 一次取回操作者三个维度的可见集合（三件套一条 SQL 同返，
// 省往返）。全租户（All=true）不展开全量 ID，调用方直接关掉本地过滤。
func (s *Service) GetScope(ctx context.Context, auth AuthContext) (Scope, error) {
	var sc Scope
	err := s.withTx(ctx, auth, func(q *gen.Queries, _ pgx.Tx) error {
		row, err := q.GetScope(ctx, auth.UserID)
		if err != nil {
			return err
		}
		sc = Scope{
			Users:  newScopeSet(row.UserIds),
			Depts:  newScopeSet(row.DeptIds),
			Groups: newScopeSet(row.GroupIds),
		}
		return nil
	})
	return sc, err
}

// GetUserRoles 枚举操作者的全部有效角色（展示/审计/外部缓存）。
func (s *Service) GetUserRoles(ctx context.Context, auth AuthContext) ([]gen.SysRole, error) {
	var roles []gen.SysRole
	err := s.withTx(ctx, auth, func(q *gen.Queries, _ pgx.Tx) error {
		var err error
		roles, err = q.GetUserRoles(ctx, auth.UserID)
		return err
	})
	return roles, err
}

// GetPermissionCodes 枚举操作者的全部权限码（去重排序），供前端
// 菜单渲染、网关/远程系统整包缓存（配合 GetScopeVersion 失效）。
func (s *Service) GetPermissionCodes(ctx context.Context, auth AuthContext) ([]string, error) {
	var codes []string
	err := s.withTx(ctx, auth, func(q *gen.Queries, _ pgx.Tx) error {
		var err error
		codes, err = q.GetPermissionCodes(ctx, auth.UserID)
		return err
	})
	return codes, err
}

// ------------------------------------------------------------
// 主数据类
// ------------------------------------------------------------

// ListVisibleUsers 在操作者的可见范围内按指定字段拉用户（需求 5：
// 业务表加扩展列后重新生成，调用方式不变；敏感列被 @hidden 挡住）。
// fields 传 nil 拉全量投影；limit 0 用表级默认页大小；after 传游标
// 续翻（与 offset 模式互斥，nil 即首页）。
func (s *Service) ListVisibleUsers(ctx context.Context, auth AuthContext, fields []string, limit uint32, after *string) (dynq.Result[gen.SysUser], error) {
	var res dynq.Result[gen.SysUser]
	err := s.withTx(ctx, auth, func(_ *gen.Queries, tx pgx.Tx) error {
		p := gen.ListSysUserParams{
			Scope: &gen.SysUserScope{UserID: auth.UserID}, // 可见范围强制注入（fail-closed）
			Limit: limit,
			After: after,
		}
		for _, f := range fields {
			p.SelectFields = append(p.SelectFields, dynq.FieldName(f))
		}
		var err error
		res, err = gen.ListSysUser(ctx, tx, p)
		return err
	})
	return res, err
}

// ------------------------------------------------------------
// 缓存失效类
// ------------------------------------------------------------

// GetScopeVersion 取 auth 用户的范围版本（租户级 + 用户级一次取回）。
// 外部进程缓存 GetScope/GetPermissionCodes 等结果后，定期比对：
// 两个版本都未变即安全续用，任一变化即重拉（ADR-0008）。
func (s *Service) GetScopeVersion(ctx context.Context, auth AuthContext) (Version, error) {
	var v Version
	err := s.withTx(ctx, auth, func(q *gen.Queries, _ pgx.Tx) error {
		row, err := q.GetScopeVersion(ctx, auth.UserID)
		if err != nil {
			return err
		}
		v = Version{Tenant: row.TenantVersion, User: row.UserVersion}
		return nil
	})
	return v, err
}
