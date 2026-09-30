# 守卫函数三态数组契约：NULL=全租户（in_any）

sqlc_gen_dynamic v0.1.2 新增 `in_any` 数组三态守卫，生成谓词 `(fn(...) IS NULL OR col = ANY(fn(...)))`：fn 返回 NULL → 放行全部、`{}` → 拒绝全部、非空数组 → ANY 匹配。据此守卫函数三件套从行集物化形态（见 ADR-0004）回归 fun.sql 的数组三态契约：NULL 仅由"任一有效角色 data_scope=7"显式分支返回，无归属行（owner 三列全 NULL）经 NULL 放行对全租户可见、对其余档位仍不可见。本决策取代 ADR-0004，并修订 ADR-0002 的返回形态细节（单参决策不变）。

## Consequences

- in_any 是**显式放行**方向（与 `in` 的 fail-closed 相反）：函数侧纪律——NULL 只能由 data_scope=7 分支返回，别处写错返回 NULL 会放开整表；CASE 判序保证用户无效/漏设租户时走 `'{}'` 拒绝分支（my_roles 为空即不可能命中 7 分支）。
- fn 在谓词中出现两次（IS NULL 判别 + ANY 匹配），STABLE 函数两次求值结果一致，无一致性风险。
- 与 [basic_db_table](https://github.com/JNinng/basic_db_table) fun.sql 的守卫函数完全同构（时称 fn_perm_*，模板已对齐更名为 fn_accessible_*）；跨租户边界仍由 RLS 承担（NULL 放行只放行当前租户内全部行）。
