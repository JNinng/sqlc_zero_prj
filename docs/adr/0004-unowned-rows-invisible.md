# 无归属行不可见：IN 守卫形态下的 fail-closed 语义

> Status: superseded by [ADR-0005](0005-in-any-three-state-guard.md) ——插件 v0.1.2 的 in_any 守卫使 NULL=全租户契约可直接落地，无归属行恢复对全租户可见。以下为历史决策，保留存档。

@scope 守卫的生成形态是 `owner_col IN (SELECT * FROM fn(...))`，归属列全为 NULL 的行对三条守卫恒不命中——因此无归属行对**所有**视角（含 data_scope=7 全租户）不可见。这是行集物化守卫与 fun.sql `NULL=不限` 约定的唯一语义分叉，选择保留 fail-closed：无归属行是数据完整性异常（写入业务行必须携带归属三元组至少一项），不可见即不可泄漏，与体系"缺省拒绝"的哲学一致。业务侧的对应纪律：INSERT 业务行时由应用层强制填充归属。
