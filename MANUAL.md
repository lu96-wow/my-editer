# MANUAL —— 消费者手册

只用 `(require "core/editor.rkt")`。它给你三类东西：

1. **原子**：`point`、`buffer`、`window`、`screen`、`events`、`patch`、宽字符工具。
2. **editor 中性面**：构造、查询、位置解析、标注读、投影。
3. **两个操作面**：程序面（默认不动视图）、用户面（焦点 + 账本）。

内部机制（`state.rkt`、`write.rkt`、`reaction.rkt`）不在入口里，不用碰。

---

## 0. 快速开始

```racket
(require "core/editor.rkt")

;; 用户编辑：在焦点 view 的光标处插入，cursor 前进，可撤销
(define ed (editor-open "hello\nworld"))
(define-values (ed* report) (editor-edit ed (edit-insert "hi ")))
(editor-buffer->string ed* 0)        ; => "hi hello\nworld"
(editor-point ed*)                    ; => (point 0 3)

;; 程序编辑：显式位置，默认不动任何光标
(define-values (ed2 _r) (editor-edit-at ed 0 (point 1 0) (edit-insert "> ")))
(editor-point ed2)                    ; 仍是 (point 0 0)

;; 渲染
(require "core/editor.rkt")
(define scr (editor->screen ed*))    ; screen：交后端画
```

---

## 1. 位置与编辑描述

| 名字 | 语义 |
|---|---|
| `point` | 位置 `(line col)`，0-based，`col` 是字符索引；唯一位置表示 |
| `point-clamp` | 把位置夹到 `[0,line-count) × [0,行宽]` |
| `point-line` | `point` → 行 |
| `point-col` | `point` → 列 |
| `point<?` | 位置字典序比较 |
| `point=?` | 位置相等 |
| `point<=?` | 位置偏序 |
| `edit-desc` | 一次替换 `[start,end) → new-text`；跨层唯一契约 |
| `edit-desc-start` | 区间起点 |
| `edit-desc-end` | 区间终点（半开） |
| `edit-desc-new-text` | 取代文本 |
| `edit-desc-after-position` | 插入文本之后的点 |
| `edit-desc-map-position` | 编辑前位置 → 编辑后位置（`#f` = 落在删除区内） |
| `edit-desc-inverse` | 由生效 desc + 旧文本求逆 |
| `selection` | 选区 `(anchor head)`；空选区 = 普通光标 |
| `selection-point` | 选区光标点（= `head`） |
| `selection-range` | 选区半开区间 `[start,end)` |
| `selection-empty?` | 是否空选区 |
| `caret` | 构造光标（= 同位置的空选区） |
| `caret?` | 是否光标（空选区） |
| `caret-point` | 光标点（= `head`） |

## 2. 编辑动作（可传的值）

| 名字 | 语义 |
|---|---|
| `edit-insert-char` | 构造「插入一个字符」的 op |
| `edit-insert` | 构造「插入/替换」的 op（空选区=插，非空=替换选区） |
| `edit-newline` | 换行 |
| `edit-backspace` | 退格（可跨行合并） |
| `edit-delete` | 前向删除（可跨行合并） |
| `edit-splice` | 通用逃生门：显式区间替换 |

## 3. buffer —— 文档原子（无光标）

| 名字 | 语义 |
|---|---|
| `buffer-open` | 由字符串建 buffer |
| `buffer->string` | 导出为字符串 |
| `buffer->lines` | 导出为行表 |
| `buffer-line-count` | 行数（≥ 1） |
| `buffer-line-ref` | 第 i 行文本 |
| `buffer-line-length` | 第 i 行长度 |
| `buffer-clamp-point` | 对 buffer 夹紧位置 |
| `buffer-point->offset` | 位置 → 绝对偏移 |
| `buffer-offset->point` | 绝对偏移 → 位置 |
| `buffer-range-text` | 取 `[start,end)` 文本 |
| `buffer-apply-edit` | 施加 desc（带守卫） |
| `buffer-apply-edit-trusted` | 施加 desc（跳守卫） |
| `buffer-edit-desc-inverse` | 用编辑前 buffer 求逆 |
| `buffer-apply-edit-batch` | 批量施加（同坐标系、不重叠）；返回 `(values 新buffer 生效descs 逆)` |
| `buffer-put-property` | 写行内区间标注 |
| `buffer-get-property` | 读某点标注 |
| `buffer-remove-property` | 清某键标注 |
| `buffer-put-properties-many` | 一次写多段（一次 tick） |
| `buffer-put-restrict` | 写约束槽（只读等） |
| `buffer-restrict-at` | 某点的约束槽（`restrict`；是否只读用 `restrict-read-only?`） |
| `buffer-remove-restrict` | 清约束区间 |
| `buffer-restrict-runs` | 某行的约束段 |
| `buffer-property-runs` | 某行某键的表现层区间段 `(start end val)` |
| `buffer-tick` | 单调计数：任何改动都涨 |
| `buffer-apply-patches` | 施加插件 delta |
| `buffer-content-eq?` | 内容是否同一（区分文本改动/仅标注） |

## 4. patch —— 插件 delta

| 名字 | 语义 |
|---|---|
| `patch` | 一个 key 在 `[first-line,last-line]` 上清旧写新 |
| `patch-key` | 归属键 |
| `patch-first-line` | 起始行 |
| `patch-last-line` | 结束行 |
| `patch-segs` | 写入段 `(line start end val)` |

## 5. window —— 视口（纯视图）

| 名字 | 语义 |
|---|---|
| `window-open` | 建视口 |
| `window-point` | 本视口 primary 光标 |
| `window-selections` | 本视口选区集（已规范化） |
| `window-primary` | 主选区下标 |
| `window-set-selections` | 设一组选区 |
| `window-add-selections` | 并入一组选区（并集） |
| `window-remove-selections` | 去掉一组选区（差集） |
| `window-map-selections` | 对每个选区 head 施加 point→point 变换 |
| `window-clamp-selections` | 把选区夹回合法域并规范化 |
| `window-set-point` | 设成单个空选区（光标） |
| `window-set-buffer` | 换绑 buffer（夹紧光标） |
| `window-left` | 光标左移 |
| `window-right` | 光标右移 |
| `window-up` | 按视觉行上移 |
| `window-down` | 按视觉行下移 |
| `window-home` | 行首 |
| `window-end` | 行尾 |
| `window-ensure-point` | 调整滚动使光标可见 |
| `window-point->screen` | 光标 → 屏幕坐标 |
| `window-point-at->screen` | 指定点 → 屏幕坐标 |
| `window-screen->point` | 屏幕坐标 → 位置 |
| `window-set-size` | 设尺寸 |
| `window-set-mode` | `clip` 或 `wrap` |
| `window-scroll-clip` | 相对滚动（clip：按 buffer 行） |
| `window-scroll-visual` | 相对滚动（按 mode 分派到 clip/wrap） |
| `window-hscroll` | 水平滚动 |

## 6. 投影 —— window → screen

| 名字 | 语义 |
|---|---|
| `window->screen` | 视口 → 一帧画面 |
| `screen` | 输出契约：文本 runs（文档）+ cursors/selections（视图 overlay）两条通道 |
| `screen-rows` | 行数 |
| `screen-cols` | 列数 |
| `screen-row-runs` | 第 r 行的 run 序列（文档文本 + face） |
| `screen-cursor-row` | primary 光标行 |
| `screen-cursor-col` | primary 光标列 |
| `screen-cursors` | 所有光标（`(listof cursor)`，含 primary） |
| `screen-selections` | 所有选中区段（`(listof region)`） |
| `cursor` | 视图 overlay：一个光标点 `(row col face primary?)` |
| `cursor-row` | 光标显示行 |
| `cursor-col` | 光标显示列 |
| `cursor-face` | 光标语义 face（hash） |
| `cursor-primary?` | 是否主光标 |
| `region` | 视图 overlay：一段选中区间 `(row start-col end-col face)` |
| `region-row` | 区间显示行 |
| `region-start-col` | 区间起始显示列 |
| `region-end-col` | 区间结束显示列（半开） |
| `region-face` | 区间语义 face（hash） |
| `run` | 一段同 face 文本 |
| `run-col` | run 起始显示列 |
| `run-text` | run 文本 |
| `run-face` | run 语义样式 |
| `screen-compose` | 把多块 screen 拼成一帧 |
| `screen-diff-rows` | 两帧差异行 |
| `screen->string` | 调试：画面转字符串 |

## 7. 事件（后端喂进来的输入）

| 名字 | 语义 |
|---|---|
| `text-event` | 文本输入 |
| `key-event` | 按键 |
| `mouse-press-event` | 鼠标按下 |
| `mouse-wheel-event` | 滚轮 |
| `resize-event` | 终端尺寸变化 |
| `quit-event` | 退出 |
| `modifiers` | 修饰键组合 |

## 8. 宽字符

| 名字 | 语义 |
|---|---|
| `char-display-width` | 字符显示宽度 |
| `string-display-width` | 字符串显示宽度 |
| `index->column` | 字符索引 → 显示列 |
| `column->index` | 显示列 → 字符索引 |
| `snap-column-forward` | 显示列吸附到字符起点 |

---

## 9. editor 平台

### 9.1 构造 / 生命周期

| 名字 | 语义 |
|---|---|
| `editor-open` | 建一个单 buffer 单 view 的 editor |
| `editor-open-buffer` | 新开 buffer + view；`#:focus?` 控制是否抢焦点 |
| `editor-add-view` | 给某 buffer 加 view；`#:sync`、`#:focus?` |
| `editor-close-view` | 关一个 view |
| `editor-close-buffer` | 关一个 buffer 及其 view |
| `editor-focus-view` | 聚焦某 view |
| `editor-focus-buffer` | 聚焦某 buffer 的首个 view |

### 9.2 查询

| 名字 | 语义 |
|---|---|
| `editor?` | 是否 editor |
| `editor-buffer-count` | buffer 数 |
| `editor-view-count` | view 数 |
| `editor-buffers` | buffer-entry 列表 |
| `editor-views` | view 列表 |
| `editor-focus` | 当前焦点 view id |
| `editor-buffer-id` | 焦点 view 的 buffer id |
| `editor-buffer` | 取 buffer 值 |
| `editor-buffer-name` | 取 buffer 名 |
| `editor-view-buffer-id` | 某 view 的 buffer id |
| `editor-view-sync` | 某 view 的同步策略 |
| `editor-sync` | 焦点 view 的同步策略 |
| `editor-selections` | 焦点 view 的选区集 |
| `editor-view-selections` | 某 view 的选区集 |
| `editor-point` | 焦点 view 光标 |
| `editor-view-point` | 某 view 光标 |
| `editor-height` | 焦点 view 可视高度 |
| `editor-width` | 焦点 view 可视宽度 |
| `editor-view-height` | 某 view 高度 |
| `editor-view-width` | 某 view 宽度 |
| `editor-top-line` | 焦点 view 顶部行 |
| `editor-view-top-line` | 某 view 顶部行 |
| `editor-view-mode` | 某 view `clip`/`wrap` |
| `editor-view-left-col` | 某 view 水平滚动列 |
| `editor-view-top-seg` | 某 view 折行段 |
| `editor-mode` | 焦点 view `clip`/`wrap` |
| `editor-left-col` | 焦点 view 水平滚动列 |
| `editor-top-seg` | 焦点 view 折行段 |
| `buffer-entry-id` | buffer id（投影） |
| `buffer-entry-name` | buffer 名（投影） |
| `view-id` | view id（投影） |
| `view-buffer-id` | view 看哪个 buffer（投影） |
| `view-sync` | view 的同步策略（投影） |

### 9.3 位置解析（程序入口）

| 名字 | 语义 |
|---|---|
| `editor-buffer->string` | buffer 全文字符串 |
| `editor-buffer->lines` | buffer 行表 |
| `editor-buffer-line-count` | 行数 |
| `editor-buffer-line-ref` | 第 i 行 |
| `editor-buffer-line-length` | 第 i 行长度 |
| `editor-buffer-clamp-point` | 夹紧位置（不需要 view） |
| `editor-buffer-point->offset` | 位置 → 偏移 |
| `editor-buffer-offset->point` | 偏移 → 位置 |
| `editor-buffer-range-text` | 取区间文本 |
| `editor-buffer-tick` | 某 buffer 的变化计数（乐观并发 / 合并的版本戳） |
| `editor-buffer-content-eq?` | 两个 buffer 的文本是否同一（区分文本改动/仅标注） |

### 9.4 标注

| 名字 | 语义 |
|---|---|
| `editor-get-property` | 读某点标注 |
| `editor-restrict-at` | 某点的约束槽（`restrict`） |
| `editor-remove-restrict` | 清约束区间 |
| `editor-restrict-runs` | 某行约束段 |
| `editor-property-runs` | 某行某键的标注区间段 `(start end val)` |
| `editor-put-property` | 写标注（程序面） |
| `editor-remove-property` | 清标注 |
| `editor-put-properties-many` | 一次写多段 |
| `editor-put-restrict` | 写约束槽 |
| `editor-apply-patches` | 施加插件 delta |

### 9.5 编辑

| 名字 | 语义 |
|---|---|
| `editor-edit-at` | 在显式 `(bid, point)` 编辑；`#:reaction 'none` 默认不动视图 |
| `editor-edit-at-batch` | 一次施加一批（同坐标系、不重叠）`edit-desc`；`#:record? #t` 整批记一步 |
| `editor-view-edit` | 在指定 view 光标处编辑；leader + ensure + 记账本；不改焦点 |
| `editor-edit` | focus 糖：在焦点 view 光标处编辑 |

`editor-edit-at` 的参数：

- `#:reaction` —— `none`（默认，字面不动）或 `map`（光标跟随文本）。
- `#:trusted?` —— 跳过 `read-only` 守卫（格式化器）。
- `#:record?` —— 是否记一步账本（默认不记）。

`editor-edit-at-batch` 的 `descs` 同坐标系、互不重叠（= LSP `TextEdit[]`）；被
`read-only` 守卫拒的 desc 静默丢弃（用 `#:trusted? #t` 强制）；`#:record? #t` 把整批
记成**一步**撤销。report 的 `change-report-edits` 是实际生效的 descs（施加顺序）。

### 9.6 视图命令（程序面：按 vid 定位，只动指定的一个 view，**不经过焦点**）

| 名字 | 语义 |
|---|---|
| `editor-view-set-point` | 设某 view 光标 |
| `editor-view-set-selections` | 设某 view 的选区集（多光标）；可选 primary 下标 |
| `editor-view-add-selections` | 并入选区；`#:primary?` 可让新加的成为主选区 |
| `editor-view-remove-selections` | 去掉选区（差集） |
| `editor-view-collapse-selections` | 回单光标（保留 primary） |
| `editor-view-set-size` | 设某 view 尺寸 |
| `editor-view-set-mode` | 设某 view `clip`/`wrap` |
| `editor-view-set-top-line` | 设某 view 顶部行 |
| `editor-view-set-top-seg` | 设某 view 折行段（wrap） |
| `editor-view-set-left-col` | 设某 view 水平滚动列 |
| `editor-view-set-sync` | 设某 view 同步策略 |
| `editor-view-set-buffer` | 让某 view 改看另一个 buffer |
| `editor-set-sync` | focus 糖：设焦点 view 同步策略 |
| `editor-set-buffer` | focus 糖：让焦点 view 改看另一个 buffer |
| `editor-set-buffer-name` | 重命名某 buffer |
| `editor-set-point` | focus 糖：设焦点 view 光标 |
| `editor-set-selections` | focus 糖：设焦点 view 选区集（可选 primary） |
| `editor-add-selections` | focus 糖：并入选区（`#:primary?`） |
| `editor-remove-selections` | focus 糖：去掉选区 |
| `editor-collapse-selections` | focus 糖：回单光标 |
| `editor-set-mode` | focus 糖：设焦点 view 的 `clip`/`wrap` |
| `editor-set-size` | focus 糖：设焦点 view 尺寸 |
| `editor-set-top-line` | focus 糖：设焦点 view 顶部行 |
| `editor-set-top-seg` | focus 糖：设焦点 view 折行段 |
| `editor-set-left-col` | focus 糖：设焦点 view 水平滚动列 |

### 9.7 导航（用户面：ensure + follow 镜像；原语按 vid，focus 糖见下）

| 名字 | 语义 |
|---|---|
| `editor-view-left` | 某 view 左移 |
| `editor-view-right` | 某 view 右移 |
| `editor-view-up` | 某 view 上移（视觉行） |
| `editor-view-down` | 某 view 下移（视觉行） |
| `editor-view-home` | 某 view 行首 |
| `editor-view-end` | 某 view 行尾 |
| `editor-view-goto` | 某 view 跳到位置并 ensure |
| `editor-view-scroll` | 滚动某 view |
| `editor-left` | focus 糖：焦点 view 左移 |
| `editor-right` | focus 糖：右移 |
| `editor-up` | focus 糖：上移 |
| `editor-down` | focus 糖：下移 |
| `editor-home` | focus 糖：行首 |
| `editor-end` | focus 糖：行尾 |
| `editor-goto` | focus 糖：跳到位置并 ensure |
| `editor-scroll` | focus 糖：滚动焦点视口 |

### 9.8 撤销 / 重做

| 名字 | 语义 |
|---|---|
| `editor-view-undo` | 按某 view 所属 buffer 撤销一步；不改焦点 |
| `editor-view-redo` | 按某 view 所属 buffer 重做一步 |
| `editor-undo` | focus 糖：按焦点 view 的 buffer 撤销一步 |
| `editor-redo` | focus 糖：重做一步 |
| `editor-can-undo?` | 可否撤销 |
| `editor-can-redo?` | 可否重做 |
| `editor-undo-depth` | 撤销栈深 |
| `editor-redo-depth` | 重做栈深 |

### 9.9 投影

| 名字 | 语义 |
|---|---|
| `editor->screen` | 焦点 view → screen |
| `editor-view->screen` | 某 view → screen |
| `editor-point->screen` | 焦点光标 → 屏幕坐标 |
| `editor-view-point->screen` | 某 view 光标 → 屏幕坐标 |
| `editor-screen->point` | 屏幕坐标 → 焦点 view 位置 |
| `editor-view-screen->point` | 屏幕坐标 → 某 view 位置 |

### 9.10 命令返回值

| 名字 | 语义 |
|---|---|
| `change-report` | 一次命令的影响：行区间 + 生效 desc 列表 |
| `change-report-first-line` | 首行（新坐标系） |
| `change-report-last-line` | 末行（新坐标系） |
| `change-report-edits` | 施加顺序的 `edit-desc` 列表 |

命令返回 `(values editor (or/c #f change-report))`；`#f` 表示什么都没发生。
`change-report-edits` 按**施加顺序**给出这次生效的编辑，每个 desc 的坐标是施加它之前
的状态——可直接嗂 `edits-map-position`，或转成 LSP 的增量 `didChange`。
