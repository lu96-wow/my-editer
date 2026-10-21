# edit-tui/source

解析来源的统一层。

```text
source-snapshot = id + path + authority + version + text
```

- `authority`：`buffer | disk | virtual`
- `version`：buffer document version / disk stamp / virtual version
- `text`：当前快照

规则：

```text
同一 path：open buffer > disk
buffer 关闭：回退到 disk snapshot（如果存在）
disk 更新：不覆盖 open buffer，只更新 by-id 里的备用 snapshot
virtual：没有 path，只按 id 存在
```

模块：

```text
model.rkt   纯值：source-id / source-snapshot / 路径规范化
store.rkt   纯索引：by-id / by-path，buffer 优先级，authoritative 视图
api.rkt     唯一对外面
```

不读磁盘、不做 IO。磁盘读取、editor resource 同步放在 boot/source-sync 层。
