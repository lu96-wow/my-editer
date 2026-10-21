# edit-tui/source

解析来源的统一层。解析层只消费 snapshot，不关心文本来自 buffer 还是磁盘。

## 模型

```text
source-id
  kind    buffer | disk | virtual
  value   buffer id / 规范化 path / virtual id

source-snapshot
  id
  path        规范化绝对路径 | #f
  authority   buffer | disk | virtual
  version     缓存失效键
  text        当前快照
```

不变量：

```text
disk source 必须有 path
buffer / virtual 可以没有 path
source-id.kind == snapshot.authority
同一 path 的优先级由 source-store 决定，model 不处理
```

## store

```text
by-id    source-id -> snapshot
by-path  规范化 path -> 当前权威 source-id
```

规则：

```text
同一 path：open buffer > disk
disk 更新：不覆盖 open buffer，只更新 by-id 里的备用快照
buffer 关闭：by-path 回退到 disk（如果 by-id 里存在）
同一 path 新 buffer：替换旧 buffer override
同一 buffer id 改 path：先摘掉旧 path 索引，再写新 path
virtual：没有 path，只按 id 存在
```

`source-store-authoritative-snapshots` 返回 workspace 应该看到的“当前真相”：

```text
by-path 的权威快照
+ 没有 path 的 buffer / virtual
- 被 buffer 覆盖的 disk
```

## API

```racket
;; model
(disk-source-id-for-path path)
(buffer-source id path text #:version v)
(disk-source path text #:version v)
(virtual-source id text #:version v)
(source-normalize-path path)
(source-snapshot-cache-key snapshot) ; (id, version)

;; store
(source-store-ref store source-id)
(source-store-ref-by-path store path)
(source-store-path-id store path)

(source-store-set-buffer store buffer-id path text #:version v)
(source-store-set-disk store path text #:version v)
(source-store-set-virtual store id text #:version v)

;; 手动更新已有 source：保持 id/path/authority，只换 text/version
(source-store-update store source-id text #:version v)

(source-store-remove-source store source-id)
(source-store-remove-buffer store buffer-id)
(source-store-remove-disk store path)

(source-store-authoritative-snapshots store)
(source-store-all-snapshots store)
```

## 边界

| 情况 | 行为 |
|---|---|
| open buffer 与 disk 同 path | buffer 胜 |
| buffer 打开时 disk 更新 | 只更新 by-id 备用 disk，不改 by-path |
| buffer 关闭，disk 存在 | 回退最新 disk |
| buffer 关闭，disk 不存在 | path 索引删除 |
| buffer save-as 到新 path | 旧 path 回退/删除，新 path 指向 buffer |
| 两个 buffer 同 path | 新 buffer 替换旧 override；旧 buffer 从 by-id 删除 |
| disk 文件删除但 buffer 还开着 | disk by-id 删除，buffer 仍是权威 |
| disk path = #f | 参数错误 |
| remove-disk path = #f | no-op，返回原 store |
| buffer / virtual 无 path | 只按 id 存在，不进入 by-path |
| 同一文件不同 symlink / 大小写路径 | 目前按不同 path 处理，后续可由 path resolver 统一 |
| dirty buffer 关闭 | source 层只移除来源；保存/确认由 editor 负责 |
| 手动更新 buffer | `source-store-update` 保持 identity/path/authority |
| 手动 refresh disk | `source-store-update` 更新备用 disk；buffer 仍优先 |
| 更新不存在的 source | 参数错误，不静默新增 |

## 分工

```text
source/model  纯值 + 规范化
source/store  纯索引 + buffer/disk 优先级
boot/source-sync
  读磁盘、stat / version、把 editor resource 转成 snapshot
lang/racket/workspace
  消费 source snapshot，维护 analysis / 跨 buffer 依赖
```

source 层不做 IO，也不做 dirty / save 确认。
