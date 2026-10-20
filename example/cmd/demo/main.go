// demo 是数据权限体系的可运行验收入口：重建独立测试库 → 按序应用
// schema.sql / rls.sql / operate.sql / expose.sql / seed.sql → 以 test_u
// 普通角色连接执行 24 个场景：[1]-[12] 验证读（各档数据范围能看到哪些
// 行、多角色并集、忘注入 Scope 直接报错、漏设租户什么都看不到、加
// 过滤条件只能看得更少）；[13]-[17] 验证写（分配角色、批量分配多个
// 角色、修改归属前的权限判断）；[18]-[24] 验证权限查询接口（单点
// 判断与维度选择、批量过滤、功能权限码、可视范围三态、用户字段
// 投影、范围版本缓存失效、组成员/新增用户失效与停用用户边界）。
// 任一断言失败即以非零码退出。
//
// 运行（在 example/ 目录）: go run ./cmd/demo
// 连接: 管理库默认 postgres://postgresql:root@localhost:5432/postgres，
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
	"sqlc_zero_prj/perm"
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
	fmt.Printf("   测试库 %s 已重建（schema.sql → rls.sql → operate.sql → expose.sql → seed.sql）\n", testDBName)
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
	// [17] 放在写场景最后：批量演示会给 lisi 追加角色 106，改变 lisi 的可见范围，
	// 不能影响前面的 [15]
	d.assignBatchScenario(ctx)
	// [18]-[24] 权限查询接口（perm 服务层）：注意 [17] 已给 lisi 加了
	// 角色 106（指定人 lisi/wangwu），lisi 的可见用户是 {3,4}，
	// 后续断言都按这个状态写
	d.checkVisibleScenario(ctx)
	d.filterVisibleScenario(ctx)
	d.permissionCodeScenario(ctx)
	d.scopeStateScenario(ctx)
	d.listVisibleUsersScenario(ctx)
	// [23] 给 lisi 追加角色 104 会再改变 lisi 的可见范围
	d.versionBumpScenario(ctx)
	// [24] 再改组成员/新增用户并停用 lisi，最后恢复
	d.versionBoundaryScenario(ctx)

	fmt.Println()
	if d.fails > 0 {
		return fmt.Errorf("%d 个场景断言失败", d.fails)
	}
	fmt.Println("全部 24 个场景通过 ✔")
	return nil
}

// setup 重建测试库并按序应用 schema / rls / operate / expose / seed
// （需超级用户管理连接，超级用户绕过 RLS 才能灌入含跨租户行的种子），
// 随后补授 test_u 连接权。
func setup(ctx context.Context) error {
	adminDSN := os.Getenv("ZERO_DEMO_ADMIN_DSN")
	if adminDSN == "" {
		adminDSN = adminDSNDefault
	}
	admin, err := pgx.Connect(ctx, adminDSN)
	if err != nil {
		return fmt.Errorf("连接管理库失败(本地 PostgreSQL 不可达?): %w", err)
	}
	// 先踢掉还连在测试库上的会话（上次运行残留/IDE 连接），否则 DROP 会被占用阻塞
	if _, err := admin.Exec(ctx,
		"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()",
		testDBName); err != nil {
		admin.Close(ctx)
		return err
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
	for _, f := range []string{"schema.sql", "rls.sql", "operate.sql", "expose.sql", "seed.sql"} {
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

// assignBatch [17] 批量分配：多个角色一次判断、一次写入；
// 任一角色不通过则整批拒绝，一个都不写。
func (d *demo) assignBatchScenario(ctx context.Context) {
	fmt.Println("== [17] 写入权限：批量分配多个角色 ==")
	err := example.Begin(ctx, d.pool, d.auth("zhouba"), func(s *example.Session) error {
		// [102, 103] 给用户 10：102 通过（部门命中配置），
		// 103 不通过（zhouba 看不见用户 10，103 又没有分发配置）
		// → 整批拒绝，一个都不写
		_, err := example.RoleAdminAPI{}.AssignRoles(ctx, s, []int64{102, 103}, userID["market"])
		var den *example.ErrDenied
		fmt.Printf("   zhouba 批量分配 [102 103] → user=10:\n      %v\n", err)
		d.check(errors.As(err, &den), "任一角色不通过，整批拒绝（102 虽通过也不写）")
		has, err := s.Q().HasUserRole(ctx, gen.HasUserRoleParams{UserID: userID["market"], RoleID: 103})
		if err != nil {
			return err
		}
		d.check(!has, "被拒的角色没有写入")
		return nil
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	err = example.Begin(ctx, d.pool, d.auth("admin"), func(s *example.Session) error {
		// [103, 106] 给 lisi：admin 全可见，两个都通过；
		// lisi 种子里已有 103 → 跳过，实际新增 1 条
		inserted, err := example.RoleAdminAPI{}.AssignRoles(ctx, s, []int64{103, 106}, userID["lisi"])
		fmt.Printf("   admin 批量分配 [103 106] → user=3: 新增 %d 条\n", inserted)
		d.check(err == nil && inserted == 1, "全部通过批量写入；已拥有的角色（103）跳过，新增 1 条")
		if err != nil {
			return nil
		}
		has, err := s.Q().HasUserRole(ctx, gen.HasUserRoleParams{UserID: userID["lisi"], RoleID: 106})
		if err != nil {
			return err
		}
		d.check(has, "新角色 106 已写入")
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

// ------------------------------------------------------------
// [18]-[24] 权限查询接口：perm 服务层的本地调用演示（外部进程
// 经 HTTP/gRPC 调用的就是这些方法；传输外壳由宿主自包）。
// 前置状态注意：[17] 已给 lisi(3) 追加角色 106（指定人 3/4），
// lisi 可见用户 {3,4}、可见部门 {3}（103 仅本人也含自己部门）。
// ------------------------------------------------------------

func int64Ptr(v int64) *int64 { return &v }

// checkVisibleScenario [18] 单点判断 + 维度选择：同一条归属，
// 换维度掩码结论不同；掩码 0 fail-closed。
func (d *demo) checkVisibleScenario(ctx context.Context) {
	fmt.Println("== [18] 权限查询：单点判断 + 维度选择（lisi） ==")
	svc := perm.New(d.pool)
	cases := []struct {
		dims    perm.Dims
		target  perm.OwnerTriplet
		want    bool
		comment string
	}{
		{perm.DimAll, perm.OwnerTriplet{UserID: int64Ptr(3)}, true, "全维度：归属人=自己，可见"},
		{perm.DimAll, perm.OwnerTriplet{DeptID: int64Ptr(2)}, false, "全维度：归属部门=2 不在可见部门 {3} 内"},
		{perm.DimDept, perm.OwnerTriplet{DeptID: int64Ptr(3)}, true, "仅部门维度：归属部门=自己所在部门，可见"},
		{perm.DimUser, perm.OwnerTriplet{DeptID: int64Ptr(3)}, false, "仅归属人维度：目标没有归属人，部门不参与判定"},
		{perm.Dims(0), perm.OwnerTriplet{UserID: int64Ptr(3)}, false, "无效掩码 0：没有选中任何维度，fail-closed"},
	}
	for _, c := range cases {
		ok, err := svc.CheckVisible(ctx, d.pauth("lisi"), c.dims, c.target)
		if err != nil {
			d.fails++
			fmt.Printf("   FAIL 执行错误: %v\n", err)
			continue
		}
		fmt.Printf("   dims=%d target(u=%v,d=%v,g=%v) → %v\n",
			c.dims, deref(c.target.UserID), deref(c.target.DeptID), deref(c.target.GroupID), ok)
		d.check(ok == c.want, c.comment)
	}
}

// filterVisibleScenario [19] 批量过滤：外部系统一次传一组归属三元组，
// 只回可见子集（保持顺序）；FilterVisibleRows 的远程优化用法。
func (d *demo) filterVisibleScenario(ctx context.Context) {
	fmt.Println("== [19] 权限查询：批量过滤返回可见子集（wujiu·指定人 {3,4}） ==")
	svc := perm.New(d.pool)
	targets := []perm.OwnerTriplet{
		{UserID: int64Ptr(3)},  // 可见
		{UserID: int64Ptr(9)},  // 看不见的人
		{DeptID: int64Ptr(2)},  // 指定人档位看不见任何部门
		{UserID: int64Ptr(4)},  // 可见
		{},                     // 无归属：非全租户角色不可见
		{GroupID: int64Ptr(1)}, // 指定人档位看不见任何组
	}
	visible, err := svc.FilterVisibleRows(ctx, d.pauth("wujiu"), perm.DimAll, targets)
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	var got []any
	for _, t := range visible {
		got = append(got, fmt.Sprintf("(u=%v,d=%v,g=%v)", deref(t.UserID), deref(t.DeptID), deref(t.GroupID)))
	}
	fmt.Printf("   6 条 → 可见 %d 条: %v\n", len(visible), got)
	d.check(len(visible) == 2 &&
		visible[0].UserID != nil && *visible[0].UserID == 3 &&
		visible[1].UserID != nil && *visible[1].UserID == 4,
		"期望可见子集 [(u=3), (u=4)]（保持传入顺序，只回允许部分）")

	// 维度收窄到仅部门：同样 6 条全不可见（指定人档位部门集合为空）
	visible, err = svc.FilterVisibleRows(ctx, d.pauth("wujiu"), perm.DimDept, targets)
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	fmt.Printf("   dims=DimDept 时可见 %d 条\n", len(visible))
	d.check(len(visible) == 0, "仅部门维度：指定人档位没有部门可见性，全拒")
}

// permissionCodeScenario [20] 功能权限轴：HasPermission 单码判断 +
// GetPermissionCodes 全量枚举（lisi: 角色 103，106 无菜单）。
func (d *demo) permissionCodeScenario(ctx context.Context) {
	fmt.Println("== [20] 权限查询：功能权限码（lisi vs admin） ==")
	svc := perm.New(d.pool)
	for _, c := range []struct {
		user string
		code string
		want bool
	}{
		{"lisi", "sys:user:query", true},
		{"lisi", "sys:user:create", false},
		{"admin", "sys:user:create", true},
	} {
		ok, err := svc.HasPermission(ctx, d.pauth(c.user), c.code)
		if err != nil {
			d.fails++
			fmt.Printf("   FAIL 执行错误: %v\n", err)
			continue
		}
		fmt.Printf("   %-8s has %q → %v\n", c.user, c.code, ok)
		d.check(ok == c.want, fmt.Sprintf("%s 持有 %q 应为 %v（角色→菜单→权限码）", c.user, c.code, c.want))
	}
	codes, err := svc.GetPermissionCodes(ctx, d.pauth("lisi"))
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	fmt.Printf("   lisi 全部权限码: %v\n", codes)
	d.check(slices.Equal(codes, []string{"sys:dept", "sys:dept:query", "sys:manage", "sys:user", "sys:user:query"}),
		"lisi 权限码 = 角色 103 的菜单（201/202/203/236/237），去重排序")
}

// scopeStateScenario [21] 可视范围三态：All（全租户）/ 数组 / 空数组。
func (d *demo) scopeStateScenario(ctx context.Context) {
	fmt.Println("== [21] 权限查询：可视范围三态（admin / lisi / zhengshi） ==")
	svc := perm.New(d.pool)
	type want struct {
		user                 string
		all                  bool
		users, depts, groups []int64
	}
	for _, w := range []want{
		{"admin", true, nil, nil, nil},
		// lisi = 103 仅本人（自己 + 所在部门 3）∪ 106 指定人 3/4
		// （指定人档位的部门集合含目标用户归属部门，见 fn_accessible_dept_ids）
		{"lisi", false, []int64{3, 4}, []int64{3, 4}, []int64{}},
		{"zhengshi", false, []int64{10}, []int64{5}, []int64{}},
	} {
		sc, err := svc.GetScope(ctx, d.pauth(w.user))
		if err != nil {
			d.fails++
			fmt.Printf("   FAIL 执行错误: %v\n", err)
			continue
		}
		fmt.Printf("   %-9s users=%v depts=%v groups=%v\n", w.user,
			scopeRepr(sc.Users), scopeRepr(sc.Depts), scopeRepr(sc.Groups))
		d.checkScopeSet(w.user+" users", sc.Users, w.all, w.users)
		d.checkScopeSet(w.user+" depts", sc.Depts, w.all, w.depts)
		d.checkScopeSet(w.user+" groups", sc.Groups, w.all, w.groups)
	}
}

func scopeRepr(s perm.ScopeSet) string {
	if s.All {
		return "All(全租户)"
	}
	return fmt.Sprintf("%v", s.IDs)
}

func (d *demo) checkScopeSet(label string, got perm.ScopeSet, all bool, want []int64) {
	if all {
		d.check(got.All && got.IDs == nil,
			fmt.Sprintf("%s: 期望 All=true 且不展开全量 ID，实得 %s", label, scopeRepr(got)))
		return
	}
	gotIDs := slices.Clone(got.IDs)
	slices.Sort(gotIDs)
	wantIDs := slices.Clone(want)
	slices.Sort(wantIDs)
	d.check(!got.All && slices.Equal(gotIDs, wantIDs),
		fmt.Sprintf("%s: 期望 %v（All=false），实得 %s", label, want, scopeRepr(got)))
}

// listVisibleUsersScenario [22] 用户字段投影：可见范围内按指定字段拉
// 用户（呼叫中心扩展字段场景的模板用法；敏感列被 @hidden 挡住）。
func (d *demo) listVisibleUsersScenario(ctx context.Context) {
	fmt.Println("== [22] 权限查询：可见用户 + 字段投影（zhouba） ==")
	svc := perm.New(d.pool)
	res, err := svc.ListVisibleUsers(ctx, d.pauth("zhouba"), []string{"id", "nickname"}, 20, nil)
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	var ids []int64
	for _, u := range res.Items {
		ids = append(ids, u.ID)
	}
	slices.Sort(ids) // 动态列表默认按 created_at 倒序，断言按集合比较
	fmt.Printf("   可见用户(id,nickname): ")
	for _, u := range res.Items {
		fmt.Printf("%d:%s ", u.ID, u.Nickname)
	}
	fmt.Println()
	d.check(slices.Equal(ids, []int64{2, 6, 7}), "期望 [2 6 7]（技术部子树 {2,7,8} 内用户）")
	d.check(len(res.Items) > 0 && res.Items[0].Nickname != "" && res.Items[0].Password == "",
		"指定字段已投影、未选字段为零值（password 不可选，@hidden）")
}

// versionBumpScenario [23] 范围版本：给 lisi 追加角色只 bump lisi 的
// 用户级版本，租户级与他人版本不动（ADR-0008 双粒度隔离）。
func (d *demo) versionBumpScenario(ctx context.Context) {
	fmt.Println("== [23] 权限查询：范围版本失效信号（双粒度隔离） ==")
	svc := perm.New(d.pool)
	before, err := svc.GetScopeVersion(ctx, d.pauth("lisi"))
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	otherBefore, err := svc.GetScopeVersion(ctx, d.pauth("wangwu"))
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	fmt.Printf("   版本 before: lisi=(租户%d,用户%d) wangwu=(租户%d,用户%d)\n",
		before.Tenant, before.User, otherBefore.Tenant, otherBefore.User)

	// admin 给 lisi 追加角色 104：真实写入触发 bump
	err = example.Begin(ctx, d.pool, d.auth("admin"), func(s *example.Session) error {
		return example.RoleAdminAPI{}.Assign(ctx, s, 104, userID["lisi"])
	})
	fmt.Printf("   admin 分配 role=104 → lisi: err=%v\n", err)
	d.check(err == nil, "追加角色写入成功（触发器随后 bump 版本）")

	after, err := svc.GetScopeVersion(ctx, d.pauth("lisi"))
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	otherAfter, err := svc.GetScopeVersion(ctx, d.pauth("wangwu"))
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	fmt.Printf("   版本 after:  lisi=(租户%d,用户%d) wangwu=(租户%d,用户%d)\n",
		after.Tenant, after.User, otherAfter.Tenant, otherAfter.User)
	d.check(after.User > before.User, "lisi 用户级版本递增（缓存应重拉）")
	d.check(after.Tenant == before.Tenant, "租户级版本不动（角色映射变更不风暴全租户）")
	d.check(otherAfter.User == otherBefore.User && otherAfter.Tenant == otherBefore.Tenant,
		"wangwu 两个版本都不动（一人变更只失效该用户缓存）")
}

// versionBoundaryScenario [24] 范围版本与枚举边界：组成员/新增用户会
// 改变其他用户的派生可见集合，必须 bump 租户级版本；停用用户的
// 角色/权限码枚举为空（与 fn_has_permission 的语义一致）。
func (d *demo) versionBoundaryScenario(ctx context.Context) {
	fmt.Println("== [24] 权限查询：组成员/新增用户失效 + 停用用户边界 ==")
	svc := perm.New(d.pool)

	// 组成员变更：zhangsan 的角色 108 指定组 2，把 sunqi(6) 加入组 2
	before, err := svc.GetScopeVersion(ctx, d.pauth("zhangsan"))
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	err = example.Begin(ctx, d.pool, d.auth("admin"), func(s *example.Session) error {
		_, err := s.Tx().Exec(ctx, `
			INSERT INTO public.sys_user_group_mapping (group_id, user_id, tenant_id, created_by)
			VALUES (2, $1, current_setting('app.tenant_id'), 1)`, userID["sunqi"])
		return err
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 组成员写入: %v\n", err)
		return
	}
	after, err := svc.GetScopeVersion(ctx, d.pauth("zhangsan"))
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	fmt.Printf("   zhangsan 版本: 租户 %d → %d\n", before.Tenant, after.Tenant)
	d.check(after.Tenant > before.Tenant, "组成员变更 bump 租户级版本（他人可见集合失效）")
	sc, err := svc.GetScope(ctx, d.pauth("zhangsan"))
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	d.check(sc.Users.Visible(userID["sunqi"]), "zhangsan 可见用户包含新入组的 sunqi(6)")

	// 新增用户：user 11 落在部门 2，进入 zhouba 的部门子树可见集合
	before, err = svc.GetScopeVersion(ctx, d.pauth("zhouba"))
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	err = example.Begin(ctx, d.pool, d.auth("admin"), func(s *example.Session) error {
		_, err := s.Tx().Exec(ctx, `
			INSERT INTO public.sys_user
			    (id, status, created_by, updated_by, tenant_id, owner_user_id, owner_dept_id, "name", nickname, "password")
			VALUES (11, 1, 1, 1, current_setting('app.tenant_id'), 1, 2, 'newuser', '新用户', 'x')`)
		return err
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 新增用户写入: %v\n", err)
		return
	}
	after, err = svc.GetScopeVersion(ctx, d.pauth("zhouba"))
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	fmt.Printf("   zhouba 版本: 租户 %d → %d\n", before.Tenant, after.Tenant)
	d.check(after.Tenant > before.Tenant, "新增用户 bump 租户级版本（部门成员集合变化）")
	sc, err = svc.GetScope(ctx, d.pauth("zhouba"))
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	d.check(sc.Users.Visible(11), "zhouba 可见用户包含新增用户 11")

	// 停用 lisi：角色/权限码枚举必须为空（与 fn_has_permission 一致）
	err = example.Begin(ctx, d.pool, d.auth("admin"), func(s *example.Session) error {
		_, err := s.Tx().Exec(ctx, `UPDATE public.sys_user SET status = 0 WHERE id = $1`, userID["lisi"])
		return err
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 停用 lisi: %v\n", err)
		return
	}
	roles, err := svc.GetUserRoles(ctx, d.pauth("lisi"))
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	codes, err := svc.GetPermissionCodes(ctx, d.pauth("lisi"))
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	has, err := svc.HasPermission(ctx, d.pauth("lisi"), "sys:user:query")
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 执行错误: %v\n", err)
		return
	}
	fmt.Printf("   停用 lisi: roles=%d codes=%d has=%v\n", len(roles), len(codes), has)
	d.check(len(roles) == 0 && len(codes) == 0 && !has,
		"停用用户的角色/权限码枚举为空，HasPermission=false")

	// 恢复 lisi，避免影响后续手工使用演示库
	err = example.Begin(ctx, d.pool, d.auth("admin"), func(s *example.Session) error {
		_, err := s.Tx().Exec(ctx, `UPDATE public.sys_user SET status = 1 WHERE id = $1`, userID["lisi"])
		return err
	})
	if err != nil {
		d.fails++
		fmt.Printf("   FAIL 恢复 lisi: %v\n", err)
		return
	}
	d.check(true, "lisi 已恢复启用")
}

type demo struct {
	pool  *pgxpool.Pool
	fails int
}

func (d *demo) auth(user string) example.AuthContext {
	return example.AuthContext{TenantID: tenantSuper, UserID: userID[user]}
}

// pauth 返回权限查询接口的身份（与 example.AuthContext 同构，
// 分属两个包，显式转换）。
func (d *demo) pauth(user string) perm.AuthContext {
	return perm.AuthContext{TenantID: tenantSuper, UserID: userID[user]}
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
