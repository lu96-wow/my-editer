# edit-tui-rebuild

重建中的编辑器基础设施。目前已完成：

```text
布局模型
命令表
face / 渲染
资源管理
API 层 / 边界约束
```

## 项目结构

```text
edit-tui-rebuild/
  main.rkt                 公共入口

  api.rkt                  统一 API 面（只聚合各领域 api.rkt）

  base/
    api.rkt                几何值：rect

  app/
    event.rkt              key / mouse / resize / paste / internal
    state.rkt              app-state
    action.rkt             view-action / quit-action
    step.rkt               event -> (values state actions)
    api.rkt                app API

  edit/
    model.rkt              自插入判读（纯）：键 -> 可打印字符
    commands.rkt           编辑操作表：插入/删除/导航/翻页/撤销
    api.rkt                edit API

  runtime/
    engine.rkt             core buffer / view 唯一拥有者
    actions.rkt            action -> engine / IO
    render.rkt             state + cache -> bytes
    loop.rkt               render / read-event / step / run-actions
    api.rkt                runtime API

  panel/
    model.rkt              panel 资源
    api.rkt                panel API

  config/
    model.rkt              panel kind 规则
    api.rkt                config API
    theme/
      default.rkt          默认主题：base/frame/chrome/overlay 小表
                           + 顶层 append 成扁平表并安装

  face/
    model.rkt              face 值 / 分层合成
    api.rkt                face API

  render/
    theme.rkt              style / theme / 默认主题
    core.rkt               core piece -> tui bytes
    layout.rkt             layout -> panels -> bytes
    api.rkt                render API

  layout/
    model.rkt              split tree / panel 状态 / layout-solve / 接缝
    api.rkt                layout API

  focus/
    model.rkt              焦点导航
    api.rkt                focus API

  command/
    table.rkt              命令表 / stack
    key.rkt                键 token = 标签 + 原始字节（绑定 / 事件同一表示）
    api.rkt                command API

  chrome/
    status.rkt             状态栏投影 / 同步
    input.rkt              输入栏：prompt / 文本 / submit / cancel
    api.rkt                chrome API

  filetree/
    model.rkt              文件树状态 / 行结构
    scan.rkt               读目录（唯一 IO）
    lines.rkt              纯行投影
    panel.rkt              每帧同步到 core view
    commands.rkt           导航 / 展开 / 打开文件
    api.rkt                filetree API

  projection/
    geometry.rkt           layout -> core panel 投影
    api.rkt                projection API

  resource/
    model.rkt              resource / save / quit / prompt
    api.rkt                resource API

  demo/
  test/
```

规则：

- 每个领域目录内部放 `model.rkt`（实现）+ `api.rkt`（对外功能面）；
- 顶层 `api.rkt` 只聚合领域 API；
- `main.rkt` 只再导出 `api.rkt`；
- 非实现层不得 require 领域实现文件。

## API 边界约束

允许：

```text
main.rkt
*/api.rkt
外部 core/*
```

不允许：

```text
layout/model.rkt
panel/model.rkt
command/table.rkt
projection/geometry.rkt
... 任何非 api.rkt 的领域实现文件
```

如果 API 不够：

```text
先补对应领域的 api.rkt，不要在下游绕过 API 直接调实现。
```

`test/api-boundary.rkt` 会扫描所有非领域目录下的 `.rkt`，发现越界 require 直接失败。

## 布局模型

```text
layout = split tree + panel 资源

node  = leaf(panel-id)
      | split(id, axis, left, right, ratio)

panel = id / kind / views / active
        fixed-w / fixed-h
        hidden? / restore
        borders / face / weight
```

关键约定：

- `rect` 不进树，由 `layout-solve` 计算；
- 渲染列表 `(listof core panel)` 是投影，不是结构真相；
- 只有 `kind = 'editor` 的 panel 默认能 split（由 config 决定）；
- split 新 panel 是空 panel，不抢焦点；
- 固定尺寸是 `fixed-w` / `fixed-h` 实际值，`#f` = flex；
- 隐藏 leaf 仍在树里，兄弟吸收父 rect；
- 显示按隐藏时记录的 `rect / parent-rect` 比例恢复；
- 删除 leaf 时父 split 塌缩到兄弟；
- 最后一个 editor 用 `layout-panel-clear-content` 保留 slot；
- 接缝属于 split 节点；拖动改 ratio，再重新 `layout-solve`；
- 固定轴阻止接缝拖动；
- min / max 不进状态，由 config 在 API 边界使用；
- 焦点回退顺序：兄弟子树 → 逐层向上 → 第一个可聚焦 panel；
- 一个 panel 槽可挂多个 view，顺序切换用 `layout-panel-cycle-active-view`。

## 统一 API

```racket
(require "edit-tui-rebuild/main.rkt")
```

### base

```racket
rect rect?
rect-x rect-y rect-w rect-h
rect-right rect-bottom
rect-inset rect-inset-sides
rect-contains?
```

### panel

```racket
(make-panel id kind #:views #:active #:fixed-w #:fixed-h
            #:hidden? #:restore #:borders #:face #:weight)
(make-empty-editor-panel id)
(panel-view p)
(panel-visible? p)
(panel-set-views p views [active])
(panel-set-active p view-id)
(panel-set-fixed p axis value)
(panel-set-hidden p hidden? [restore])
(panel-set-restore p restore)
```

### config

```racket
(make-panel-rule #:splittable? #:hideable? #:deletable? #:focusable?
                 #:min-w #:max-w #:min-h #:max-h)
(make-layout-config #:rules #:default)
default-config
(config-panel-rule config kind)
(config-panel-splittable? config kind)
(config-panel-hideable? config kind)
(config-panel-deletable? config kind)
(config-panel-focusable? config kind)
(panel-rule-min-size rule axis)
(panel-rule-max-size rule axis)
```

### layout 状态

```racket
(make-layout #:root #:panels #:focus #:next-split-id)
empty-layout
(make-leaf panel-id)

(layout-panel-add l p)
(layout-panel l id)
(layout-panel-resources l)
(layout-panel-ids l)
(layout-visible-panel-ids l)
(layout-panel-update l id f)
(layout-panel-visible? l id)
(layout-panel-fixed-size l id axis)
(layout-subtree-visible? l node)

(layout-focus l)
(layout-set-focus l id)
```

### panel 内 view 切换

```racket
(layout-panel-view-ids l id)
(layout-panel-active-view l id)
(layout-panel-set-active-view l id view-id)
(layout-panel-cycle-active-view l id [step])  ; 1 下一个，-1 上一个
```

### 结构操作

```racket
(layout-split l target-id dir new-panel-id #:ratio #:config)
(layout-panel-attach l target-id dir panel #:ratio)
(layout-panel-remove l id #:config)
(layout-panel-clear-content l id)
(layout-panel-set-fixed l id axis value)
(layout-split-set-ratio l split-id ratio)
```

### 隐藏 / 显示

```racket
(layout-panel-hide l area id #:config)
(layout-panel-show l area id)
(layout-focus-fallback l config id)
```

### layout-solve / 接缝 / 拖动

```racket
(layout-solve l area)                  ; -> layout-solution
(layout-solution-panel-rects s)        ; panel-id -> rect
(layout-solution-split-rects s)        ; split-id -> rect
(layout-solution-seams s)              ; (listof seam)
(layout-panel-rects l area)            ; panel-id -> rect
(layout-split-rects l area)            ; split-id -> rect
(layout-seams l area)                  ; (listof seam)
(layout-seam-at l area row col)        ; seam | #f
(layout-panel-id-at l area row col)    ; panel-id | #f

(layout-seam-resize l area split-id delta #:config)
(layout-seam-drag-start l area row col #:config)   ; -> drag | #f
(layout-seam-drag-move l area drag row col #:config)
```

### 焦点导航

```racket
(layout-panel-focusable? l config id)
(layout-focusable-panels l area config)       ; view = panel-id
(layout-focus-panel-at l area config row col) ; panel-id | #f
(layout-focus-neighbor l area config from-id dir)
```

### 校验

```racket
(layout-validate l area config)  ; (listof violations)
(layout-valid? l area config)
```

### 投影

```racket
(layout->render-panels l area)                     ; view = active
(layout->render-panels l area #:focus-panel 'editor) ; + 焦点框（见下）
(layout->hit-panels l area)                        ; view = panel-id
```

#### 焦点窗高亮

焦点框不改布局、不改内容、也不进命中投影，做法是利用 core 的边框合成：

- 在焦点 panel 的边框格上再叠一个**空 core panel**（`view = #f`），
  `face = 'focused-border`，`weight` 比所有 panel 大；
- core 对同一格按 `weight` 取边框 face（`core/view/border.rkt`：
  “weight 大的边框格赢，焦点框抬边框用”），于是焦点框的 face 赢；
- 边框格位置要算对：
  - 自己画的边 → 就在 rect 边上；
  - 被邻居共享的边（共享边框时这条边是邻居画的）→ 缝在 rect 外一格，框外扩 1；
  - 谁都没画的边（屏幕外沿 / 没边框）→ 不画，避免盖内容；
- 焦点框只出现在 `layout->render-panels`，`layout->hit-panels` 不含它；
  隐藏的焦点 panel 不出框。

`weight` / `face` 都从 layout 的焦点 + panel 模型推出来，
渲染层只认 core panel；换颜色 = 换主题里的 `focused-border`。

### face

```racket
face?
face-fg face-bg face-attrs
face-empty
face-set-fg face-set-bg face-set-attrs
face-add-attr face-remove-attr face-has-attr?
compose-face
compose-layers
```

### render

```racket
rgb?
style?
define-theme!

render-piece
render-pieces
render-clear
face-fragment

(layout-sync! layout area)  ; panels + panels-sync!（尺寸写回 core view）
(render-layout layout area #:focus-panel #:cache #:sync?)
```

`render-layout` 默认 `#:sync? #t`，先把 panel 内容尺寸写回 view，再渲染。

`render-layout`：

```text
layout -> core panels
       -> render-display-patch
       -> render-pieces
       -> (values cache' bytes)
```

### theme 配置

主题不放 API，放在 `config/theme/`：

```racket
(require "edit-tui-rebuild/config/theme/default.rkt")
```

配置层是小表：

```racket
base-theme
frame-theme
chrome-theme
overlay-theme
```

安装层 append 成扁平表：

```racket
default-theme
(define-theme! default-theme)
```

require 即安装，换主题 = 换 require：

```racket
(require "edit-tui-rebuild/config/theme/dark.rkt")
```

### 输入：标签 + 字节

输入的中间状态不转成 char / symbol，token 就是终端给的那一份：

```racket
(struct key-token (tag bytes))
```

- `tag`：`'key`（单字节）| `'ctrl` | `'alt` | `'utf8` | `'mod-seq`（CSI 带修饰）
  | 命名键 `'up 'down 'left 'right 'home 'end 'insert 'del 'pageup 'pagedown 'backtab`
- `bytes`：原始字节

runtime 用 `tui:read-event/raw` 取 `(values type data mods)`，适配层直接
`(key-token type data)` 往下传；mouse / paste / resize 也保留原始载荷
（paste 是 bytes，写 buffer 时才解一次 UTF-8）。

绑定和事件是同一种表示，`key` 把可读写法编码成 ANSI 字节：

```text
(key 'a 'ctrl)      -> ('ctrl    . #"\x01")
(key 'A)            -> ('key     . #"A")
(key 'left)         -> ('left    . #"\e[D")
(key 'left 'shift)  -> ('mod-seq . #"\e[1;2D")
(key #\中)          -> ('utf8    . "中" 的 UTF-8)
```

命名键的多种终端写法（CSI `ESC[A` / SS3 `ESC OA` / 老式 `ESC[1~`）由
`raw->key` 按 tag 归一成一种规范字节，表里每个绑定只存一条。

终端不能区分的组合自然共用 token，所以不存在「死绑定」：

```text
C-i = Tab        C-m = Enter      C-[ = Escape
C-h = Backspace  C-j = Enter（LF 归一成 CR）
```

想真正区分它们得开 kitty keyboard protocol / xterm modifyOtherKeys。

### app / 事件循环

```racket
(key-event token)
(mouse-event token row col)
(resize-event rows cols)
(paste-event bytes)
(internal-event kind data)
(quit-event)

(make-app-state #:layout #:resources #:focus-resource
                #:overlays #:editor-tables
                #:pending #:area #:quit? #:message)

;; 编辑 / 导航 / 鼠标落点都是 view-action，runtime 解释成 core 调用
(view-action kind view-id data)
;;;   kind : insert | paste | backspace | delete | kill-line
;;        | nav | point | select | scroll | ensure | undo | redo
;;   insert/paste data = 原始 UTF-8 bytes（engine 写 buffer 时解码一次）
;;   nav   data = dir | (list dir extend?)
;;   point data = (list row col)   ; 内容区相对坐标（0 基）
(quit-action)

(step state event)  ; -> (values state' actions)
```

命令值约定：

```text
command-table 叶子是 (state -> (values state' actions))
```

按键序列 / 动态遮蔽沿用：

```text
overlay tables ++ focused resource command-stack
```

### runtime

```racket
(make-engine)
(engine-create-buffer! engine did name text)
(engine-create-view! engine vid did)
(engine-view-object engine vid)
(engine-view-text engine vid)
(engine-doc-text engine did)
(engine-doc-version engine did)
(engine-apply-view-action! engine action)

(run-actions state engine actions)  ; -> state'

(render-frame state engine cache)   ; -> (values cache' bytes)

(run-loop state engine
          #:read-event ...
          #:write-bytes ...)
```

`run-loop`：

```text
render
read-event
step
run-actions
quit? -> exit
```

没有 hook / settle / 通用 effect。action 是数据，runtime 同步解释。  
view-id -> core view 在 runtime engine 里解析；State 不存 core 句柄。

### 文件树

```racket
(empty-filetree)
(make-filetree #:view #:line #:cursor-dirty? #:expanded #:rows)
(filetree-toggle-expand f path)
(filetree-set-view / set-line / set-rows)
(filetree-sync-line f line)      ; sync 从 view 读回镜像（不要求下推）

(filetree-lines root expanded opened dir-lister)
(filetree-line-at rows line)

(dir-entries path)
(filetree-normalize-path path)

(sync-filetree! state engine)  ; -> state'
;;   rows 按 (root, expanded, opened) 缓存
;;   光标归 core view（它就是普通 buffer）：
;;     键盘移动 -> state 改 cursor 并置 cursor-dirty?，sync 推给 view；
;;     鼠标点击 -> 普通 point action 改 view，sync 直接读回来当镜像。

(filetree-command-table)
(filetree-panel-stack)
(filetree-install-state state view root #:panel-id)
(filetree-nav-command kind)
(filetree-enter-command state)
;; 没有文件树专用的点击/光标逻辑：走通用 point action
```

行为：

- root / dir：Enter 展开 / 折叠；
- file：Enter 打开；
  - 已打开且已挂 panel：聚焦已有 panel；
  - 已打开但 detached：进入 placement；
  - 未打开：read-file -> resource-open -> placement；
- placement（临时表，完毕自动解除）：
  - 开始时就压入 `placement-table`，焦点不在 editor 上会自动落到第一个 editor；
  - ↑←→↓ 在 editor 之间改焦点（跳过 filetree / status）；
  - Enter 放入当前焦点 editor；鼠标点目标 editor 也可；
  - Esc 取消；
  - 放入 / 取消后 `clear-placement` 把临时表从 overlays 摘掉，普通键位恢复。
- 鼠标点 filetree 行：就是普通 buffer 的 point action —— 点哪行光标到哪行
  （滚动、行尾、空白处的行为与编辑器完全一致），state 里的 cursor 只是镜像。

### 状态栏 / 输入栏

```racket
(status-install-state state view-id)
(status-line state engine)
(sync-status! state engine)

(input-install-state state panel-id status-view input-view)
(input-state* state)
(input-active? state)
(input-open state)
(input-close state)
(input-sync! state engine)
(input-handle-key state event)  ; -> (values state' actions) | #f
```

状态栏：

```text
focus resource path/name
line:col
dirty *
pending keys
message
```

输入栏：

- prompt 来自 `resource-prompt`；
- `Enter` -> `resource-submit`；
- `Esc` / `C-g` -> `resource-cancel`；
- 普通字符 / Backspace 修改输入文本；
- confirm prompt 会把文本转成 symbol（save / skip / save-all / skip-all / cancel）。

输入栏和状态栏共用同一个 panel 的 views：

```racket
(make-panel 'status 'status
            #:views '(status-view input-view)
            #:active status-view
            #:fixed-h 1)
```

### 资源管理

```racket
resource-store-empty
resource-open
resource-ref
resource-list
resource-focus
resource-set-focus
resource-pending

resource-id
resource-name
resource-doc-id
resource-views
resource-file-path
resource-binding-stack
resource-version
resource-saved-version
resource-path
resource-dirty?
resource-writable?
resource-view-ids
resource-command-stack
resource-set-command-stack

resource-mark-edited
resource-save
resource-save-as
resource-save-done

resource-request-close
resource-request-quit
resource-prompt
resource-submit
resource-cancel

resource-action?
resource-action-kind
resource-action-data
resource-event?
resource-event-kind
resource-event-data

prompt?
prompt-id
prompt-kind
prompt-resource-id
prompt-label
prompt-value
prompt-choices
pending?
pending-kind
pending-ids
pending-index
pending-mode
```

规则：

```text
path 有值   -> 能落文件
path = #f   -> 不能落文件，保存前先要路径
dirty       -> version != saved-version
```

`resource-open` 返回 action 数据：

```text
create-buffer / create-view
```

保存返回：

```text
write-file
```

关闭 / 退出完成后返回：

```text
close-resource / quit
```

输入面板只调用：

```text
resource-prompt
resource-submit
resource-cancel
```

### 命令表

两层：

```text
command-table        一张表：key-sequence -> command
command-table-stack  (listof command-table)：动态遮蔽
```

```racket
(keys [key ... value] ...)
(command-table-add t seq value)
(command-table-from-bindings binds)
(command-table-bindings t)
(command-table-merge t ...)         ; 多张合成一张，左边优先
(command-table-lookup t seq)        ; 'command / 'prefix / 'unbound

command-table-stack-empty
(command-table-stack-from-tables ts)
(command-table-stack-push stack t)
(command-table-stack-pop stack)
(command-table-stack-remove stack t)
(command-table-stack-lookup stack seq)
```

规则：

- stack 顶层先查；
- 顶层返回 `command` / `prefix` 就停止；
- 只有 `unbound` 才落到下一层；
- 弹窗可以 `push` 临时表，关闭时 `pop` / `remove`。

## 性能

每帧固定成本只和「可见格数」有关，和文档 / 目录行数无关：

- **行投影有缓存**：filetree 按 `(root, expanded 集合, opened 集合)` 缓存 rows。
  三者不变就不重扫目录（`dir-entries` 每个 entry 要 3 次 stat，3000 行 ≈ 30ms）。
  外部文件变了用 `C-r` 手动刷新。
- **UI 写回幂等**：`engine-set-view-lines!` 记住上次写进 view 的
  `(lines faces)`；内容没变就不重建 document、不推历史、不动 selections。
  core 的 render cache 以 document 版本为键 —— 不换 document 就命中增量渲染。
- **按键路径不绕圈**：token 就是 `(tag . bytes)`，事件原样往下传；
  自插入的 bytes 直接进 `insert` action，只在写 buffer 时解一次 UTF-8。
  没有 char / symbol 互转，也不把整张表展开成 Unicode 绑定。

参考数字（80×24、filetree 3000 行、内容不变的一帧）：

```text
旧：每帧 filetree-lines（重扫目录）≈ 42ms + engine-set-view-lines!（重建 document）≈ 32ms
新：每帧 sync + render ≈ 0.5ms
```

## 测试

```sh
bash edit-tui-rebuild/test/run.sh
```

测试也统一只 require `../main.rkt`（外部 core panel 访问器除外）。

## demo

```sh
racket edit-tui-rebuild/demo/layout.rkt
racket edit-tui-rebuild/demo/three-panels.rkt
racket edit-tui-rebuild/demo/interactive.rkt
```

交互 demo：

```text
C-w ←→↑↓   拆分当前 editor
C-b        显隐 filetree
C-x ←→↑↓   焦点移动
C-s        保存当前 resource（无 path -> Save as 输入栏）
C-q        退出（dirty -> 确认输入栏）
鼠标拖接缝  resize
鼠标点面板  聚焦
鼠标点 buffer 内容区 -> 主光标落到点击处（filetree 也一样，它就是普通 buffer）

焦点窗口的边框用主题里的 `focused-border` 高亮（`config/theme/default.rkt` 换颜色）。
```

编辑（`edit/commands.rkt`，作为 editor 文档的 per-doc 键表）：

```text
直接打字                插入（任意可打印字符，含大写 / 中文）
Enter / Tab             换行 / 插入两个空格
Backspace / Delete / C-d 删前 / 删后一个字符
←→↑↓ Home End           导航
Shift+方向 / Shift+Home End  扩展选区
C-a / C-e               行首 / 行尾（C-f / C-b 逐字符）
PageUp / PageDown       翻页
C-k                     删到行尾
C-z / C-y               撤销 / 重做
```

表里匹配不到的键由 `edit-self-insert` 兜底：可打印字符 -> 插入焦点
editor view；非 editor 面板 / 有前缀未完成 / placement 中则回 `unbound`。
所以命令表不必把 Unicode 全集写进去。

> 关于 C-i：终端里 Ctrl-I 和 Tab 是同一个字节 0x09，所以它们本来就是
> **同一个 token**（`(key 'i 'ctrl)` ≡ `(key 'tab)`），绑 Tab 就能收到 C-i。
> C-h / C-m / C-j / C-[ 同理（见上一节「输入：标签 + 字节」）。
> 想真正区分这些键需要 kitty keyboard protocol / xterm modifyOtherKeys。

文件树：

```text
C-x ← 聚焦 filetree
鼠标点行       选中该行
↑↓ / Home End  选行
Enter          展开目录 / 打开文件（文件 -> 进入 placement）
C-r            重扫目录（行投影有缓存，外部文件变化不会自动反映）
```

placement（打开文件后自动进入）：

```text
↑←→↓  在 editor 之间改焦点（跳过 filetree / status）
Enter 放入当前焦点 editor
鼠标点 editor 放入
Esc   取消
```
