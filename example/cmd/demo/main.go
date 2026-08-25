// demo 是数据权限体系的可运行验收入口：重建独立测试库 → 按序应用
// schema.sql / rls.sql / operate.sql / seed.sql → 以 test_u 普通角色连接
// 执行 16 个场景：[1]-[12] 验证读（各档数据范围能看到哪些行、多角色
// 并集、忘注入 Scope 直接报错、漏设租户什么都看不到、加过滤条件只能
// 看得更少）；[13]-[16] 验证写（分配角色、修改归属前的权限判断）。
// 任一断言失败即以非零码退出。
//
// 运行（在仓库根目录）: go run ./example/cmd/demo
// 连接:管理库默认 postgres://postgresql:root@localhost:5432/postgres，
// 可经 ZERO_DEMO_ADMIN_DSN 覆盖；测试库 sqlc_zero_prj_demo 每次重建。
package main

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jninng/sqlc_gen_dynamic/dynq"

	"example"
	gen "sqlc_zero_prj/sqlcpg/gen"
)

const (
	adminDSNDefault = "postgres://postgresql:root@localhost:5432/postgres"
	testDBName      = "sqlc_zero_prj_demo"
	testDSNDefault  = "postgres://test_u:test_u_pwd@localhost:5432/" + testDBName
	tenantSuper     = "t-super-01"
)

// 种子用户 ID（见 sqlcpg/seed.sql §5）
var userID = map[string]int64{
	"admin": 1, "zhangsan": 2, "lisi": 3, "wangwu": 4,
	"sunqi": 6, "zhouba": 7, "wujiu": 8, "zhengshi": 9, "market": 10,
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run() error {
	ctx := context.Background()
	if err := setup(ctx); err != nil {
		return fmt.Errorf("setup: %w", err)
	}
	testDSN := os.Getenv("ZERO_DEMO_TEST_DSN")
	if testDSN == "" {
		testDSN = testDSNDefault
	}
	pool, err := pgxpool.New(ctx, testDSN)
	if err != nil {
		return fmt.Errorf("连接测试库失败(test_u): %w", err)
	}
	defer pool.Close()

	fmt.Println("== 环境 ==")
	fmt.Printf("   测试库 %s 已重建（schema.sql → rls.sql → operate.sql → seed.sql）\n", testDBName)
	fmt.Println("   场景连接: test_u 普通角色（真实承受 RLS/FORCE，非超级用户）")
	fmt.Println()

	d := &demo{pool: pool}
	d.scopeScenario(ctx, "[1] 仅本人 data_scope=1（lisi）", "lisi", []int64{1})
	d.scopeScenario(ctx, "[2] 本部门 data_scope=2（sunqi·前端组）", "sunqi", []int64{3, 9})
	d.scopeScenario(ctx, "[3] 本部门及子部门 data_scope=3（zhouba·技术部子树）", "zhouba", []int64{2, 3, 7, 9, 10})
	d.scopeScenario(ctx, "[4] 指定人 data_scope=4（wujiu→lisi/wangwu）", "wujiu", []int64{1, 4})
	d.scopeScenario(ctx, "[5] 指定部门 data_scope=5（zhengshi→市场部）", "zhengshi", []int64{5})
	d.scopeScenario(ctx, "[6] 多角色并集 仅本人∪用户组（zhangsan·普通用户+用户组演示）", "zhangsan", []int64{1, 2, 4, 6, 7})
	d.tenantWideScenario(ctx)
	d.narrowScenario(ctx)
	d.failClosedScenario(ctx)
	d.rlsMissingScenario(ctx)
	d.sysUserScenario(ctx)
	d.dictScenario(ctx)
	d.assignDenyScenario(ctx)
	d.assignExemptScenario(ctx)
	d.transferDenyScenario(ctx)
	d.transferAllowScenario(ctx)

	fmt.Println()
	if d.fails > 0 {
		return fmt.Errorf("%d 个场景断言失败", d.fails)
	}
	fmt.Println("全部 16 个场景通过 ✔")
	return nil
}

// setup 重建测试库并按序应用 schema / rls / seed（需超级用户管理连接，
// 超级用户绕过 RLS 才能灌入含跨租户行的种子），随后补授 test_u 连接权。
func setup(ctx context.Context) error {
	adminDSN := os.Getenv("ZERO_DEMO_ADMIN_DSN")
	if adminDSN == "" {
		adminDSN = adminDSNDefault
	}
	admin, err := pgx.Connect(ctx, adminDSN)
	if err != nil {
		return fmt.Errorf("连接管理库失败(本地 PostgreSQL 不可达?): %w", err)
	}
	if _, err := admin.Exec(ctx, "DROP DATABASE IF EXISTS "+testDBName); err != nil {
		admin.Close(ctx)
		return err
	}
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+testDBName); err != nil {
		admin.Close(ctx)
		return err
	}
	admin.Close(ctx)

	dbDSN, err := dsnForDB(adminDSN, testDBName)
	if err != nil {
		return err
	}
	db, err := pgx.Connect(ctx, dbDSN)
	if err != nil {
		return err
	}
	defer db.Close(ctx)

	dir := filepath.Join(repoRoot(), "sqlcpg")
	for _, f := range []string{"schema.sql", "rls.sql", "operate.sql", "seed.sql"} {
		b, err := os.ReadFile(filepath.Join(dir, f))
		if err != nil {
			return fmt.Errorf("read %s: %w", f, err)
		}
		if _, err := db.Exec(ctx, string(b)); err != nil {
			return fmt.Errorf("exec %s: %w", f, err)
		}
	}
	// rls.sql 的 DO 块已确保 test_u 存在；此处补授新库连接权
	if _, err := db.Exec(ctx, fmt.Sprintf("GRANT CONNECT ON DATABASE %q TO test_u", testDBName)); err != nil {
		return fmt.Errorf("grant connect: %w", err)
	}
	return nil
}

// scopeScenario 验证某个用户能看到 basic 表里的哪些行
// （归属人/归属部门/归属组三个过滤条件取并集）。
func (d *demo) scopeScenario(ctx context.Context, title, user string, expect []int64) {
	fmt.Printf("== %s ==\n", title)
	err := example.Begin(ctx, d.pool, d.auth(user), func(s *example.Session) error {
		roles, err := s.MyRoles(ctx)
		if err != nil {
			return err
		}
		parts := make([]string, len(roles))
		for i, r := range roles {
			parts[i] = fmt.Sprintf("%s[%s]", r.Name, example.DescribeDataScope(r.DataScope))
		}
		fmt.Printf("   身份: %s  有效角色: %s\n", user, strings.Join(parts, " + "))

		res, err := example.BasicAPI{}.List(ctx, s, &dynq.Query{})
		if err != nil {
			return err
		}
		got := basicIDs(res.Items)
		fmt.Printf("   可见 basic 行: %v\n", got)
		d.check(slices.Equal(got, expect), fmt.Sprintf("期望 %v 实得 %v", expect, got))
		return nil
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
	}
}

// tenantWideScenario [7] 全租户视角：本租户全量 + 跨租户行不可见。
func (d *demo) tenantWideScenario(ctx context.Context) {
	fmt.Println("== [7] 全租户 data_scope=7（admin） ==")
	err := example.Begin(ctx, d.pool, d.auth("admin"), func(s *example.Session) error {
		res, err := example.BasicAPI{}.List(ctx, s, &dynq.Query{})
		if err != nil {
			return err
		}
		total, err := example.BasicAPI{}.Count(ctx, s, &dynq.Query{})
		if err != nil {
			return err
		}
		got := basicIDs(res.Items)
		expect := []int64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
		fmt.Printf("   可见 basic 行: %v（total=%d）\n", got, total)
		d.check(slices.Equal(got, expect) && total == 10,
			fmt.Sprintf("期望 %v/total=10 实得 %v/total=%d；id=8 没有归属，全租户角色能看到（NULL 不过滤）；id=11 是别的租户的数据，RLS 挡住", expect, got, total))
		return nil
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
	}
}

// narrowScenario [8] 视角收窄：全租户视角叠加业务过滤 ownerUserId=3。
// 权限过滤和业务条件是叠加关系：加条件只会让结果更少，不会更多。
func (d *demo) narrowScenario(ctx context.Context) {
	fmt.Println("== [8] 视角收窄：全租户视角 + 业务过滤 ownerUserId=3 ==")
	q := &dynq.Query{Where: []dynq.Condition{{Field: "ownerUserId", Op: "eq", Value: 3}}}
	err := example.Begin(ctx, d.pool, d.auth("admin"), func(s *example.Session) error {
		total, err := example.BasicAPI{}.Count(ctx, s, q)
		if err != nil {
			return err
		}
		res, err := example.BasicAPI{}.List(ctx, s, q)
		if err != nil {
			return err
		}
		got := basicIDs(res.Items)
		fmt.Printf("   可见 basic 行: %v（total=%d）\n", got, total)
		d.check(total == 1 && slices.Equal(got, []int64{1}),
			fmt.Sprintf("期望 [1]/total=1 实得 %v/total=%d", got, total))
		return nil
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
	}
}

// failClosedScenario [9] 绕过门面直接调用生成代码且不注入 Scope：
// fail-closed——显式报错（Kind=scope），绝不静默退化为全量可见。
func (d *demo) failClosedScenario(ctx context.Context) {
	fmt.Println("== [9] fail-closed：未注入 Scope ==")
	_, err := gen.ListBasic(ctx, d.pool, gen.ListBasicParams{})
	var de *dynq.Error
	ok := errors.As(err, &de) && de.Kind == dynq.KindScope
	fmt.Printf("   err = %v\n", err)
	d.check(ok, fmt.Sprintf("期望 Kind=scope 错误，实得 ok=%v", ok))
}

// rlsMissingScenario [10] RLS 层独立验证：Scope 已注入但事务未设置
// app.tenant_id——权限过滤函数内部的查询同样受 RLS 限制，
// 什么范围都算不出来，结果为 0 行。
func (d *demo) rlsMissingScenario(ctx context.Context) {
	fmt.Println("== [10] RLS 层：漏设 app.tenant_id（admin + Scope，无 set_config） ==")
	tx, err := d.pool.Begin(ctx)
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL begin: %v\n", err)
		return
	}
	defer tx.Rollback(ctx)
	p, err := gen.ParseBasicQuery(&dynq.Query{})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL parse: %v\n", err)
		return
	}
	p.Scope = &gen.BasicScope{UserID: userID["admin"]}
	total, err := gen.CountBasic(ctx, tx, p)
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL count: %v\n", err)
		return
	}
	fmt.Printf("   可见 basic 行数: %d\n", total)
	d.check(total == 0, fmt.Sprintf("期望 0（默认全拒），实得 %d", total))
}

// sysUserScenario [11] 另一张配了 @scope 的表：用户列表同样按权限过滤。
func (d *demo) sysUserScenario(ctx context.Context) {
	fmt.Println("== [11] 用户列表 SysUser：部门子树视角（zhouba） vs 全租户（admin） ==")
	err := example.Begin(ctx, d.pool, d.auth("zhouba"), func(s *example.Session) error {
		res, err := example.SysUserAPI{}.List(ctx, s, &dynq.Query{})
		if err != nil {
			return err
		}
		ids := userIDs(res.Items)
		names := make([]string, len(res.Items))
		for i, u := range res.Items {
			names[i] = fmt.Sprintf("%d:%s", u.ID, u.Nickname)
		}
		fmt.Printf("   zhouba 可见用户: %v\n", names)
		d.check(slices.Equal(ids, []int64{2, 6, 7}),
			fmt.Sprintf("期望 [2 6 7]（技术部子树 {2,7,8} 内用户），实得 %v", ids))
		return nil
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	err = example.Begin(ctx, d.pool, d.auth("admin"), func(s *example.Session) error {
		total, err := example.SysUserAPI{}.Count(ctx, s, &dynq.Query{})
		if err != nil {
			return err
		}
		fmt.Printf("   admin 可见用户数: %d\n", total)
		d.check(total == 9, fmt.Sprintf("期望 9（t-super-01 全部用户：8 名 + 分配演示目标 market；zhaoliu 属 t-demo-01 不可见），实得 %d", total))
		return nil
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
	}
}

// dictScenario [12] 对照：没配 @scope 的表，租户内所有人都能看全。
func (d *demo) dictScenario(ctx context.Context) {
	fmt.Println("== [12] 字典 SysDictData：租户内公共数据，无行级过滤（zhangsan） ==")
	err := example.Begin(ctx, d.pool, d.auth("zhangsan"), func(s *example.Session) error {
		total, err := example.SysDictDataAPI{}.Count(ctx, s, &dynq.Query{})
		if err != nil {
			return err
		}
		fmt.Printf("   可见字典条目: %d\n", total)
		d.check(total == 11, fmt.Sprintf("期望 11（无 @scope，不做行裁剪），实得 %d", total))
		return nil
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
	}
}

// assignDeny [13] 越权分配被拒：目标用户看不见、目标部门不符合角色
// 配置，两种情况都拒绝，且确认没有写入任何数据。
func (d *demo) assignDenyScenario(ctx context.Context) {
	fmt.Println("== [13] 写入权限：越权分配被拒 ==")
	// zhangsan(可见用户 {2,3,4}) 分 103 给 sunqi(6)：
	// 目标用户不在可见范围内，被拒
	d.assignCheck(ctx, "zhangsan", 103, userID["sunqi"],
		"目标用户不在操作者可见范围内")
	// zhangsan(部门2 在 102 的分发配置里) 分 102 给 lisi(部门3)：
	// 操作者部门虽然命中配置，但目标部门不在配置里，照样被拒
	d.assignCheck(ctx, "zhangsan", 102, userID["lisi"],
		"目标部门不在角色的分发配置里（操作者部门命中配置也没用）")
}

func (d *demo) assignCheck(ctx context.Context, operator string, role, target int64, why string) {
	err := example.Begin(ctx, d.pool, d.auth(operator), func(s *example.Session) error {
		err := example.RoleAdminAPI{}.Assign(ctx, s, role, target)
		var den *example.ErrDenied
		fmt.Printf("   %s 分配 role=%d → user=%d:\n      %v\n", operator, role, target, err)
		d.check(errors.As(err, &den), why)
		has, err := s.Q().HasUserRole(ctx, gen.HasUserRoleParams{UserID: target, RoleID: role})
		if err != nil {
			return err
		}
		d.check(!has, "拒绝即无写入（先检后写，映射未落库）")
		return nil
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
	}
}

// assignExempt [14] 特例放行：目标用户不在操作者可见范围内，
// 但操作者所在部门在角色的分发配置里，照样允许分配。
func (d *demo) assignExemptScenario(ctx context.Context) {
	fmt.Println("== [14] 写入权限：部门命中角色配置，放行（zhouba·部门2 在 102 的配置里） ==")
	err := example.Begin(ctx, d.pool, d.auth("zhouba"), func(s *example.Session) error {
		// 目标 market(10·市场部)：部门 5 在 102 的配置 {2,5} 里，
		// 但 zhouba 看不见用户 10 → 靠"操作者部门命中配置"这条路放行
		err := example.RoleAdminAPI{}.Assign(ctx, s, 102, userID["market"])
		fmt.Printf("   zhouba 分配 role=102 → user=10(市场部): err=%v\n", err)
		d.check(err == nil, "目标用户不在可见范围内，但操作者部门命中角色配置，放行")
		if err != nil {
			return nil
		}
		has, err := s.Q().HasUserRole(ctx, gen.HasUserRoleParams{UserID: userID["market"], RoleID: 102})
		if err != nil {
			return err
		}
		d.check(has, "放行后映射写入成功（created_by=操作者，tenant_id 取会话值）")
		// 对照：还是这个操作者，分给 sunqi(部门7 不在配置里) → 被拒
		err = example.RoleAdminAPI{}.Assign(ctx, s, 102, userID["sunqi"])
		var den *example.ErrDenied
		fmt.Printf("   zhouba 分配 role=102 → user=6(前端组): %v\n", err)
		d.check(errors.As(err, &den), "目标部门不在角色配置里照样被拒")
		return nil
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
	}
}

// transferDeny [15] 改归属被拒：新归属的人看不见 / 这条数据本身无权操作。
func (d *demo) transferDenyScenario(ctx context.Context) {
	fmt.Println("== [15] 写入权限：改归属被拒（两头校验） ==")
	self := userID["lisi"]
	wangwu := userID["wangwu"]
	err := example.Begin(ctx, d.pool, d.auth("lisi"), func(s *example.Session) error {
		// b1(归属人=lisi，lisi 有权操作) 改归属给 wangwu(4，lisi 看不见)：拒
		err := example.BasicAPI{}.TransferOwner(ctx, s, 1, example.OwnerTriplet{UserID: &wangwu})
		var den *example.ErrDenied
		fmt.Printf("   lisi 改 b1 归属 → wangwu: %v\n", err)
		d.check(errors.As(err, &den), "新归属人不在可见范围内（看不见的人不能接手数据）")
		// b2(归属部门=2，lisi 无权操作) 改归属给 lisi 自己：拒
		err = example.BasicAPI{}.TransferOwner(ctx, s, 2, example.OwnerTriplet{UserID: &self})
		fmt.Printf("   lisi 改 b2 归属 → lisi:   %v\n", err)
		d.check(errors.As(err, &den), "这条数据本身无权操作")
		return nil
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
	}
}

// transferAllow [16] 改归属成功：两头都通过，写入后读回来确认；
// 最后演示全租户角色可以操作没有归属的数据。
func (d *demo) transferAllowScenario(ctx context.Context) {
	fmt.Println("== [16] 写入权限：改归属成功 ==")
	newOwner := userID["sunqi"]
	err := example.Begin(ctx, d.pool, d.auth("zhouba"), func(s *example.Session) error {
		// b2(归属部门=2，在 zhouba 可见部门 {2,7,8} 内) 改归属给
		// sunqi(6，在 zhouba 可见用户 {2,6,7} 内)
		err := example.BasicAPI{}.TransferOwner(ctx, s, 2, example.OwnerTriplet{UserID: &newOwner})
		fmt.Printf("   zhouba 改 b2 归属 → sunqi: err=%v\n", err)
		d.check(err == nil, "两头都通过：这条数据有权操作，新归属人可见")
		if err != nil {
			return nil
		}
		row, err := s.Q().GetBasicForUpdate(ctx, 2)
		if err != nil {
			return err
		}
		fmt.Printf("   读回 b2: owner_user_id=%v\n", deref(row.OwnerUserID))
		d.check(row.OwnerUserID != nil && *row.OwnerUserID == newOwner, "归属已修改（同一事务里读回确认）")
		return nil
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	err = example.Begin(ctx, d.pool, d.auth("admin"), func(s *example.Session) error {
		// b8(没有归属) 改归属给 wangwu：全租户角色对数据和目标都直接通过
		wangwu := userID["wangwu"]
		err := example.BasicAPI{}.TransferOwner(ctx, s, 8, example.OwnerTriplet{UserID: &wangwu})
		fmt.Printf("   admin  改 b8 归属 → wangwu: err=%v\n", err)
		d.check(err == nil, "全租户角色可以操作没有归属的数据")
		if err != nil {
			return nil
		}
		row, err := s.Q().GetBasicForUpdate(ctx, 8)
		if err != nil {
			return err
		}
		d.check(row.OwnerUserID != nil && *row.OwnerUserID == userID["wangwu"], "归属已写入")
		return nil
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
	}
}

func deref(p *int64) any {
	if p == nil {
		return "NULL"
	}
	return *p
}

type demo struct {
	pool  *pgxpool.Pool
	fails int
}

func (d *demo) auth(user string) example.AuthContext {
	return example.AuthContext{TenantID: tenantSuper, UserID: userID[user]}
}

func (d *demo) check(ok bool, detail string) {
	if ok {
		fmt.Printf("   PASS  %s\n", detail)
	} else {
		d.fails++
		fmt.Printf("   FAIL  %s\n", detail)
	}
}

func basicIDs(items []gen.Basic) []int64 {
	ids := make([]int64, len(items))
	for i, it := range items {
		ids[i] = it.ID
	}
	slices.Sort(ids)
	return ids
}

func userIDs(items []gen.SysUser) []int64 {
	ids := make([]int64, len(items))
	for i, it := range items {
		ids[i] = it.ID
	}
	slices.Sort(ids)
	return ids
}

func repoRoot() string {
	_, thisFile, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(thisFile), "..", "..", "..")
}

func dsnForDB(dsn, db string) (string, error) {
	u, err := url.Parse(dsn)
	if err != nil {
		return "", err
	}
	u.Path = "/" + db
	return u.String(), nil
}
