// demo 是数据权限体系的可运行验收入口：重建独立测试库 → 按序应用
// schema.sql / rls.sql / seed.sql → 以 test_u 普通角色连接执行 12 个场景，
// 覆盖 data_scope 1-7 逐档可见性、多角色并集、fail-closed、RLS 漏设全拒、
// 视角收窄、守卫资源与无守卫资源对照。任一断言失败即以非零码退出。
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
	"sunqi": 6, "zhouba": 7, "wujiu": 8, "zhengshi": 9,
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
	fmt.Printf("   测试库 %s 已重建（schema.sql → rls.sql → seed.sql）\n", testDBName)
	fmt.Println("   场景连接: test_u 普通角色（真实承受 RLS/FORCE，非超级用户）")
	fmt.Println()

	d := &demo{pool: pool}
	d.scopeScenario(ctx, "① 仅本人 data_scope=1（lisi）", "lisi", []int64{1})
	d.scopeScenario(ctx, "② 本部门 data_scope=2（sunqi·前端组）", "sunqi", []int64{3, 9})
	d.scopeScenario(ctx, "③ 本部门及子部门 data_scope=3（zhouba·技术部子树）", "zhouba", []int64{2, 3, 7, 9, 10})
	d.scopeScenario(ctx, "④ 指定人 data_scope=4（wujiu→lisi/wangwu）", "wujiu", []int64{1, 4})
	d.scopeScenario(ctx, "⑤ 指定部门 data_scope=5（zhengshi→市场部）", "zhengshi", []int64{5})
	d.scopeScenario(ctx, "⑥ 多角色并集 仅本人∪用户组（zhangsan·普通用户+用户组演示）", "zhangsan", []int64{1, 2, 4, 6, 7})
	d.tenantWideScenario(ctx)
	d.narrowScenario(ctx)
	d.failClosedScenario(ctx)
	d.rlsMissingScenario(ctx)
	d.sysUserScenario(ctx)
	d.dictScenario(ctx)

	fmt.Println()
	if d.fails > 0 {
		return fmt.Errorf("%d 个场景断言失败", d.fails)
	}
	fmt.Println("全部 12 个场景通过 ✔")
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
	for _, f := range []string{"schema.sql", "rls.sql", "seed.sql"} {
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

// scopeScenario 验证某用户的 basic 表可见集合（守卫三支 OR 的并集）。
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

// tenantWideScenario ⑦ 全租户视角：本租户全量 + 跨租户行不可见。
func (d *demo) tenantWideScenario(ctx context.Context) {
	fmt.Println("== ⑦ 全租户 data_scope=7（admin） ==")
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
			fmt.Sprintf("期望 %v/total=10 实得 %v/total=%d；id=8 无归属→经 NULL 放行对全租户可见（in_any 三态，ADR-0005）；id=11 跨租户→RLS 兜底", expect, got, total))
		return nil
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
	}
}

// narrowScenario ⑧ 视角收窄：全租户视角叠加业务过滤 ownerUserId=3。
// 守卫与业务过滤 AND 组合——只能收窄、永不放大。
func (d *demo) narrowScenario(ctx context.Context) {
	fmt.Println("== ⑧ 视角收窄：全租户视角 + 业务过滤 ownerUserId=3 ==")
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

// failClosedScenario ⑨ 绕过门面直接调用生成代码且不注入 Scope：
// fail-closed——显式报错（Kind=scope），绝不静默退化为全量可见。
func (d *demo) failClosedScenario(ctx context.Context) {
	fmt.Println("== ⑨ fail-closed：未注入 Scope ==")
	_, err := gen.ListBasic(ctx, d.pool, gen.ListBasicParams{})
	var de *dynq.Error
	ok := errors.As(err, &de) && de.Kind == dynq.KindScope
	fmt.Printf("   err = %v\n", err)
	d.check(ok, fmt.Sprintf("期望 Kind=scope 错误，实得 ok=%v", ok))
}

// rlsMissingScenario ⑩ RLS 层独立验证：Scope 已注入但事务未设置
// app.tenant_id——守卫函数内部查询同受 RLS 约束，可见集合为空。
func (d *demo) rlsMissingScenario(ctx context.Context) {
	fmt.Println("== ⑩ RLS 层：漏设 app.tenant_id（admin + Scope，无 set_config） ==")
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

// sysUserScenario ⑪ 守卫资源的第二形态：用户列表按数据范围裁剪。
func (d *demo) sysUserScenario(ctx context.Context) {
	fmt.Println("== ⑪ 守卫资源 SysUser：部门子树视角（zhouba） vs 全租户（admin） ==")
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
		d.check(total == 8, fmt.Sprintf("期望 8（t-super-01 全部用户；zhaoliu 属 t-demo-01 不可见），实得 %d", total))
		return nil
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
	}
}

// dictScenario ⑫ 无守卫资源对照：租户内公共数据，仅受 RLS 租户隔离。
func (d *demo) dictScenario(ctx context.Context) {
	fmt.Println("== ⑫ 无守卫资源 SysDictData：租户内公共数据（zhangsan） ==")
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
