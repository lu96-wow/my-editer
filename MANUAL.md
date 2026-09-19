# core 使用手册

> 唯一入口：`(require "core/api.rkt")`。
> 本文档是 core 的完整 API 手册：设计思路、每个原子的输入输出、以及它们怎么串起来。

---

## 0. 一句话

core 是一个**纯函数式编辑器核心**：只有底层数据原子 + 它们的纯函数变换。
不含多窗口组合 / 布局 / 命令 / 插件 / 后端。所有结构 `#:transparent`、不可变。

组合出一个编辑器，你只需要五样东西：

```
buffer（文档） + window（视口） + window->screen（投影）
             + events（输入） + screen（输出）
```

---

## 1. 设计思路

### 1.1 哲学：数据 → lambda → 数据

每个函数都是「输入值 → 纯函数 → 输出新值」，不修改输入、无全局可变状态。
core 里唯一的动态参数是测试开关 `properties-debug?`，只影响诊断、不改变语义。

### 1.2 机制 vs 策略

core 只给**机制**（原子 + 变换），不给**策略**：

| 不在 core 里 | 为什么 |
|---|---|
| 多窗口布局 | 窗口怎么摆是使用方的策略 |
| 命令/键位 | 哪个键干什么不是核心 |
| 主题/配色 | face 是语义符号，颜色是外部策略 |
| 后端 | core 只产 `screen`、只收 `events` |
| 撤销账本 | core 只给**可逆编辑代数**（逆 desc + 应用）；「记几步 / 怎么分组 / 撤销后光标回哪」是使用方策略（ARCHITECTURE §8.5） |

### 1.3 三条边界契约

```
           events ──▶ core（纯函数）──▶ screen
          (输入契约)                    (输出契约)
                         ▲
                 edit-desc（文本变更契约，内部串起所有层）
```

### 1.4 任务索引（我要做 X → 用这些）

| 我要做 | 用这些 |
|---|---|
| 插入 / 删除 / 换行 | `buffer-insert-char` / `-insert-string` / `-backspace` / `-delete` / `buffer-splice`（都返回 `(values 新值 edit-desc)`）；**配合 document 用** `edit-insert` / `edit-newline` / `edit-backspace` / `edit-delete` / `edit-splice`（可传的值，ARCHITECTURE §8.6） |
| 程序化编辑（自带坐标） | 构造 `edit-desc` → `buffer-apply-edit`（或 `buffer-apply-edit-trusted`） |
| 部分只读 | `buffer-put-restrict` + `restrict`（裸 buffer）；活文档用 `document-put-restrict`（守卫规则见 §7.5；**枚举**只读区间用 `buffer-restrict-runs`） |
| 语法高亮 / 标注 | `buffer-put-properties-many`（裸 buffer）；活文档用 `document-put-properties-many`（一次 tick） |
| 插件输出（可合并 / 异步） | `patch` + `buffer-apply-patches`（裸 buffer）；活文档用 `document-apply-patches` |
| 一个文档、多个视图 | `document-*`（§6.5） |
| 光标在别处编辑后不失效 | `edit-desc-map-position` / `edits-map-position`（一组编辑的行区间并集 → `edits-span`） |
| 宽字符量宽 / 截断 | `char-display-width` / `string-display-width` / `index->column` / `column->index` |
| 拼一块大屏 | `window->screen` + `screen-compose` |
| **撤销 / 重放** | **不在 core**：编辑走 `document-edit`（返回 `(values document (or/c #f edit-change))`——逆与编辑前光标都在 `edit-change` 里；**不记历史**）；落回走 `document-apply-descs-trusted`；纯代数在 `buffer-edit-desc-inverse` / `edit-desc-inverse`；账本自己拼（ARCHITECTURE §8.5；示范在 `history.rkt` + `editor.rkt`） |
| 看「一个编辑器长啥样」 | `editor.rkt`：最小无前端编辑器（依赖清单见文件头）——打开 → 编辑 → 导航 → 撤销/重做 → 高亮 → 只读 → 渲染成纯文本，**只含必要调用** |
| 违约会发生什么 | §10（报错 vs 夹紧），完整清单见 ARCHITECTURE §9 |

---

## 2. 术语

| 词 | 含义 | 出现处 |
|---|---|---|
| `point` | 文档位置 (line col)，0-based | `point` 结构、`window-point` |
| `cursor` | 屏幕上的可见光标（caret） | 仅 `screen-cursor-row` / `screen-cursor-col` |
| 字符索引 | buffer 里的 col（按字符数） | `point-col` |
| 显示列 | width 换算后的列（宽字符=2） | `run-col`、`vrow` 的列 |
| `face` | 语义 face 符号（`'keyword` 等） | glyph/run 的 face |

**坐标一律 0-based。** 列分「字符索引」和「显示列」，函数名用 `index`/`column` 区分。

---

## 3. 原子清单与关联总图

### 3.1 结构一览

```
文本层（无光标）
  point         位置 (line col)
  content       文本 + splice，产出 edit-desc
  properties    行内属性区间（'face 由此进画面）
  marker        会跟着文本移动的点
  overlay       会蒸发的装饰区
  buffer        文档（装配以上所有）
  patch         补丁 delta
  edit          批量编辑应用

视口层（后端无关）
  events        类型化输入事件
  width         字符 ↔ 显示列（宽字符）
  render        行 → glyph（属性变 face 的地方）
  window        视口（buffer + point + 滚动 + 尺寸）
  view          vrow 布局 + 光标/鼠标映射 + 滚动
  screen        一帧画面（run 序列）+ diff + compose
  project       window->screen 投影
  document      多视图容器（单一事实源 + 编辑漏斗 + rebase 模式）
```

### 3.2 关联总图

```
                编辑流                         渲染流
   ┌──────────────────────────┐    ┌──────────────────────────┐
   │ event                    │    │ buffer                   │
   │   → window-*（point 驱动）│    │   → render-line → glyph  │
   │   → buffer-*             │    │   → line-range->runs     │
   │   → 新 buffer + edit-desc│    │   → window->screen       │
   │   → 上层用 desc 做同步    │    │   → screen → 后端画      │
   └──────────────────────────┘    └──────────────────────────┘

属性流（写一次，全自动）：
  buffer-put-property → 编辑时自动移动 → window->screen 时变 face → 后端上色
```

---

## 4. 三条契约详解

### 4.1 `edit-desc`（文本变更）

```racket
(struct edit-desc (s-line s-col e-line e-col new-text))  ; 全操作前坐标
;; 删除 [s-line,s-col)..[e-line,e-col)，插入 new-text（可含 \n）
```

- 一次编辑 = 一个 splice。插入/删除/换行/合并/粘贴都是它的特例。
- **编辑原语返回 `(values 新值 desc)`；无操作 desc = `#f`。**
- 导航/状态原语直接返回 `window`（单值）。
- `edit-desc-map-position` / `edit-desc-after-position`：把位置映射过编辑。
- **撤销**：`buffer-edit-desc-inverse`（用「编辑前的 buffer」取回被删文本，得逆编辑）
  + `buffer-apply-edit`（应用单个 desc）；**重放**（撤销后再做一遍）用
  `buffer-apply-edit-trusted`——记录在案的编辑当年都过了 read-only 守卫，不该被**事后**才加
  的约束挡住。注意 desc 不含旧文本，逆只能由编辑前内容导出。
  底层纯代数：`edit-desc-inverse d old-text`。
- core 只给上面这组**可逆编辑代数**；**账本**（记几步、连续打字并成一步、撤销后光标回哪）
  是消费层的事，见 ARCHITECTURE §8.5（示范在 `history.rkt` + `editor.rkt`）。

### 4.2 `events`（输入）

6 个事件 + 1 个辅助，是**整程序级**的原始输入（不是 window/buffer 级）：

```racket
(struct modifiers (control alt shift meta))              ; 辅助
(struct text-event (text modifiers))                     ; 已解码文本
(struct key-event (key modifiers))                       ; 物理键
(struct mouse-press-event (button x y modifiers))        ; x/y 屏幕坐标
(struct mouse-wheel-event (direction x y modifiers))     ; x/y 屏幕坐标
(struct resize-event (rows cols))                        ; 整终端尺寸
(struct quit-event ())                                   ; 生命周期
```

- `key-event` 的 key：`char`（Ctrl+字符）| `symbol`（'up 'down 'home 'end 'backspace 'delete 'enter 'tab 'escape 等）。
- 鼠标 x/y 是**屏幕坐标**——命中的窗口、映射到 buffer 是使用方的职责（用 `window-screen->point`）。

### 4.3 `screen`（输出）

```racket
(struct run (col text face))                             ; 一段同色文本
(struct screen (rows cols row-runs cursor-row cursor-col)); 一帧画面
;; row-runs : (vectorof (listof run))  每行 run 按 col 升序
;; cursor-* : 光标位置；-1 = 不画
```

- `screen` 是"一张扁平图"，可以是单窗口投影，也可以是 N 块拼成的整屏。
- 后端只消费 `screen`，不认识 buffer/window。

---

## 5. 文本层 API（详细签名）

> **哪些是消费者 API**：§5.2 / §5.3 / §5.4 三节整节都是**模块内部**（`(require "core/api.rkt")`
> 拿不到——只能读、不能用）；消费者要的文本层入口在 §4.1 / §5.1 / §5.5 / §5.6。
> 消费者 API 的白名单就是 `core/api.rkt` 的 `provide`（213 个名字），可用 `tools/reconcile.rkt` 对账。

### 5.1 point —— 位置

| 函数 | 输入 | 输出 |
|---|---|---|
| `point` | line col | point |
| `point<?` / `point=?` / `point<=?` | a b | boolean（字典序） |
| `point-clamp` | c line-count line-length | 夹紧后的 point |
| `point-line` / `point-col` | p | nat |
| `pos<?` / `pos=?` | l1 c1 l2 c2 | boolean（直接在行列上比较，不构造 point） |

### 5.2 content —— 文本 + splice

| 函数 | 输入 | 输出 |
|---|---|---|
| `make-content` | — | 空 content（一行 ""） |
| `content-of-string` | s | content |
| `content-of-lines` | (non-empty-listof string) | content |
| `content->string` | c | string |
| `content->lines` | c | (listof string) |
| `content-line-count` | c | nat |
| `content-line-ref` | c i | string |
| `content-gap-line-ref` | c | string |
| `content-splice` | c s-line s-col e-line e-col new-text | (values content edit-desc) |
| `content-insert-char` | c ch | (values content edit-desc) |
| `content-insert-string` | c s | (values content edit-desc) |
| `content-newline` | c | (values content edit-desc) |
| `content-backspace` | c | (values content edit-desc) |
| `content-delete` | c | (values content edit-desc) |
| `edit-desc-map-position` | d l c | point \| #f（落在被删区间） |
| `edit-desc-after-position` | d | point（插入后位置） |
| `edit-desc-inverse` | d old-text | edit-desc（逆编辑；见 §4.1） |

gap 定位（返回新 content）：`content-gap-goto`。

### 5.3 properties —— 行内属性（两个槽）

每个区间带两个槽：`presentation`（开放的表现层 plist）与 `restrict`（typed 约束）。
下表前一组是表现层，`*-restrict*` 是约束槽。

| 函数 | 输入 | 输出 |
|---|---|---|
| `make-properties` | line-count | properties |
| `make-restrict` | — | restrict（空约束） |
| `properties-get` | p line col prop | any \| #f |
| `properties-at` | p line col | hash（该位置的表现层属性） |
| `properties-restrict-at` | p line col | restrict（该位置的约束；空 = 无约束） |
| `properties-put` | p line start end prop val | properties（写表现层） |
| `properties-put-restrict` | p line start end restrict | properties（写约束槽；传空约束即清除） |
| `properties-put-many` | p segs | properties |
| `properties-remove` | p line start end prop | properties |
| `properties-replace-key` | p first last prop segs | properties（清旧写新） |
| `properties-runs` | p line line-length | (listof (list start end plist)) |
| `properties-apply-edit` | p desc | properties（随编辑调整） |
| `properties-splice` | p s-line s-col e-line e-col new-text | properties |
| `properties-line-count` | p | nat |
| `properties-check` | p | properties（诊断：校验不变量） |

`segs = (listof (list line start end prop val))`。

### 5.4 marker / overlay —— 标记与装饰

| 函数 | 输入 | 输出 |
|---|---|---|
| `make-marker-table` | — | marker-table |
| `marker-table-add` | mt pos [type 'before] | (values marker-table id) |
| `marker-table-remove` | mt id | marker-table |
| `marker-table-get` | mt id | marker \| #f |
| `marker-table-all` / `marker-table-count` | mt | (listof marker) / nat |
| `marker-apply-edit` | m desc | marker |
| `marker-table-apply-edit` | mt desc | marker-table |
| `make-overlay-table` | — | overlay-table |
| `overlay-table-add` | ot start-id end-id [presentation (hash)] [#:priority 0] [#:evaporate? #f] | (values overlay-table id) |
| `overlay-table-remove` | ot id | overlay-table |
| `overlay-table-get` | ot id | overlay \| #f |
| `overlay-table-all` / `overlay-table-count` | ot | (listof overlay) / nat |
| `overlay-table-at` | ot mt line col | (listof overlay)（按 priority 降序） |
| `overlay-table-runs` | ot mt line line-length | (listof (list start end ovs)) |
| `overlay-table-apply-edit` | ot mt desc | (values overlay-table marker-table) |

### 5.5 buffer —— 文档（装配根）

| 函数 | 输入 | 输出 |
|---|---|---|
| `buffer-open` | s | buffer |
| `buffer->string` / `buffer->lines` | b | string / (listof string) |
| `buffer-line-count` / `buffer-line-ref` | b [i] | nat / string |
| `buffer-splice` | b s-line s-col e-line e-col new-text | (values buffer edit-desc) |
| `buffer-splice-trusted` | b s-line s-col e-line e-col new-text | (values buffer edit-desc)（跳过 read-only 守卫） |
| `buffer-insert-char` | b line col ch | (values buffer edit-desc) |
| `buffer-insert-string` | b line col s | (values buffer edit-desc) |
| `buffer-newline` | b line col | (values buffer edit-desc) |
| `buffer-backspace` | b line col | (values buffer edit-desc) |
| `buffer-delete` | b line col | (values buffer edit-desc) |
| `edit-insert` | s | buffer line col → (values buffer edit-desc)（把「插入」变成**可传的值**；见 ARCHITECTURE §8.6） |
| `edit-newline` / `edit-backspace` / `edit-delete` | — | 同上（就是那几个原语；形状本来就一致） |
| `edit-splice` | s-line s-col e-line e-col new-text | 同上（通用：替换区间 —— 程序化编辑的逃生门） |
| `buffer-apply-edit` | b desc | (values buffer edit-desc)（应用单个 desc，不重排/不查重叠） |
| `buffer-apply-edit-trusted` | b desc | (values buffer edit-desc)（同上，但跳过 read-only 守卫；撤销/重放用） |
| `buffer-edit-desc-inverse` | b desc | edit-desc（逆编辑；b 须是 desc 生效前的 buffer） |
| `buffer-put-property` | b line start end prop val | buffer |
| `buffer-get-property` | b line col prop | any \| #f |
| `buffer-remove-property` | b line start end prop | buffer |
| `buffer-put-properties-many` | b segs | buffer（一次 tick） |
| `buffer-put-restrict` | b line start end restrict | buffer（写约束槽；(make-restrict) 清除） |
| `buffer-read-only-at?` | b line col | boolean（该位置的约束是否含 read-only） |
| `buffer-restrict-runs` | b line | (listof (list start end restrict))（该行**约束槽**的段，恰好覆盖整行、相邻段必不同；**枚举**只读区间用——逐点问是 O(列数)，这是 O(段数)） |
| `buffer-add-marker` | b pos [type 'before] | (values buffer id) |
| `buffer-remove-marker` | b id | buffer |
| `buffer-marker-pos` | b id | point \| #f |
| `buffer-add-overlay` | b start-pos end-pos [presentation (hash)] [#:priority 0] [#:evaporate? #f] | (values buffer id) |
| `buffer-remove-overlay` | b oid | buffer |

> 另有装配层的 struct 访问器（一般用不到）：
> `buffer-content` / `buffer-properties` / `buffer-markers` / `buffer-overlays` /
> `buffer-tick` / `buffer-modified?` / `buffer-gap`，以及 `restrict` /
> `make-restrict` / `restrict-read-only?`（约束槽，见 §5.3）。

### 5.6 patch / edit —— 批量与补丁

| 函数 | 输入 | 输出 |
|---|---|---|
| `buffer-apply-patches` | b (listof patch) | buffer（按 key 清旧写新） |
| `buffer-content-eq?` | a b | boolean（eq? content） |
| `buffer-apply-edit-batch` | b (listof edit-desc) | (values buffer (listof edit-desc)) |
| `edits-map-position` | descs line col | point（跨一串编辑映射） |
| `edits-span` | descs | (values first-line last-line)（一组编辑影响到的**行区间并集**，新坐标系；空 → `(values #f #f)`） |

> `buffer-apply-edit-batch` 的返回 descs 只含**真正应用**的编辑：no-op 或被 read-only 拒绝的
> （desc = `#f`）不含在内，故可直接喂给 `edits-map-position` / `edits-span`。
>
> **增量重绘**：用 `edits-span` 取「这次要重画哪几行」——单次编辑传一条 desc，整步撤销/重放
> 传整组 desc（取并集）。`buffer-tick` 只回答「有没有变」（编辑、写属性、补丁都让它涨），
> `buffer-content-eq?` 只回答「内容变没变」（不受标注影响）。

---

## 6. 视口层 API（详细签名）

> **哪些是消费者 API**：§6.2 的 `vrow` / `window-vrows` / `layout-clip` / `layout-wrap` /
> `wrap-segments` / `line-range->runs` 与 §6.3 的 `glyph` / `render-line` / `rendered-line`
> 是**模块内部**；其余是消费者 API。`window-clamp-view` 也在白名单里——直接摆 window 的
> 消费方用它把视口夹回合法域（经 `document` 的路径会自动夹）。

### 6.1 window —— 视口

| 函数 | 输入 | 输出 |
|---|---|---|
| `window-open` | b [height 24] [width 80] | window |
| `window-set-buffer` | w b | window（point 夹紧） |
| `window-set-point` | w p | window |
| `window-set-mode` | w 'clip\|'wrap | window |
| `window-set-top` / `window-set-left` / `window-set-top-seg` | w n | window |
| `window-set-size` | w height width | window |
| `window-scroll` / `window-hscroll` | w delta | window |
| `window-goto` | w l c | window |
| `window-left` / `window-right` / `window-home` / `window-end` | w | window |

> **window 是纯视图**：只做导航/滚动/尺寸/投影，**不编辑**。编辑改共享 buffer，统一走
> `document-edit`（单窗口 = 一个视图的 document）。返回值规则：编辑入口（`document-edit`）
> 返回 `(values 新值 (or/c #f edit-change))`；导航/状态原语直接返回新值。

### 6.2 view —— vrow 布局 + 映射 + 滚动

| 函数 | 输入 | 输出 |
|---|---|---|
| `vrow` | line start-col end-col | vrow（line=-1 空行） |
| `window-vrows` | w | (vectorof vrow) |
| `line-range->runs` | b li start end | (listof run)（裁剪 + face 合并） |
| `wrap-segments` | text width | (listof (cons start end)) |
| `layout-clip` | b top-line left-col width height | (vectorof vrow) |
| `layout-wrap` | b top-line top-seg width height | (vectorof vrow) |
| `window-point->screen` | w | (values row col) \| (values #f #f) |
| `window-screen->point` | w row col | (values line col) \| (values #f #f) |
| `window-scroll-visual` | w delta | window（按视觉行滚） |
| `window-clamp-view` | w | window（把视口夹回合法域：mode-aware 夹 `top`/`top-seg`、`left-col` 吸附到字符起点） |
| `window-ensure-point` | w | window（光标跟随滚动） |
| `window-visual-move` | w delta | window（上下按视觉行移动） |
| `window-up` / `window-down` | w | window（= `window-visual-move` ∓1；按**视觉行**，不是 buffer 行） |

### 6.3 width / render —— 宽度与渲染

| 函数 | 输入 | 输出 |
|---|---|---|
| `char-display-width` | c | 0 \| 1 \| 2 |
| `string-display-width` | s | nat |
| `index->column` | s i | nat（字符索引→显示列） |
| `column->index` | s col | nat（显示列→字符索引） |
| `snap-column-forward` | s L | nat（列吸附到字符起点） |
| `render-line` | b i | rendered-line |
| `glyph` | ch face | glyph |
| `rendered-line` | glyphs | rendered-line |

### 6.4 screen / project —— 画面与投影

| 函数 | 输入 | 输出 |
|---|---|---|
| `make-screen` | rows cols | 空 screen |
| `screen-diff-rows` | old new | (listof row)（变化行） |
| `screen->text` | s | string（朴素文本投影：按 `run-col` 定位、缺口补空格、宽字符按显示宽度；**不画光标/颜色**，给测试与无前端驱动用） |
| `screen-compose` | rows cols pieces active-id | screen（拼好的大屏） |
| `window->screen` | w | screen（单窗口投影） |

`pieces = (listof (list id x y screen))`；`active-id` 决定谁的光标透出。

### 6.5 document —— 多视图容器（机制）

一个 buffer + 一组视图（视图 = window + rebase 模式），所有编辑经 `document-edit`
串行化，编辑后每个视图按**自己的模式**重新基准。
**不变量**：任一 document 内，所有视图的 buffer 都 `eq?` 同一个（不分叉）。

| 函数 | 输入 | 输出 |
|---|---|---|
| `document-open` | s | document |
| `document-of-buffer` | b | document（从已配置的 buffer 构造） |
| `document->string` / `document->lines` | doc | string / (listof string)（读文本的 document 层入口；要真 buffer 用 `document-buffer`） |
| `document-line-count` / `document-line-ref` | doc [i] | nat / string（按行读，标注循环不再下探 buffer） |
| `document-get-property` / `document-read-only-at?` | doc line col [prop] | any\|#f / boolean（读属性/只读，不向下探 buffer） |
| `document-restrict-runs` | doc line | (listof (list start end restrict))（枚举只读区间，O(段数)） |
| `document-add-view` | doc [height 24] [width 80] [p] [#:sync 'free\|'follow] | (values document index)（按尺寸开视图；不再造占位 window） |
| `document-view-count` | doc | nat |
| `document-window` | doc i | window |
| `document-view-sync` / `document-set-view-sync` | doc i [sync] | 'free\|'follow / document |
| `document-update-view` | doc i f | document（f : window → window；更新后**自动同步 follow 视图**——几何变更不动锚点、同步无害，导航则正是 follow 语义） |
| `document-sync-followers` | doc i | document（把 follow 视图对齐到 i；一般不必直接调） |
| `document-update-buffer` | doc f | document（f : buffer → buffer；**装饰写回活文档**的唯一通用入口——属性/marker/overlay/patch，不改文本、不丢视图） |
| `document-put-property` / `document-remove-property` | doc line start end [prop] [val] | document（单键写/清：只加一段或只清一段，不清旧） |
| `document-put-properties-many` | doc segs | document（语法高亮：一次 tick） |
| `document-put-restrict` | doc line start end rs | document（只读约束） |
| `document-apply-patches` | doc patches | document（插件 delta：按 key 清旧写新） |
| `document-edit` | doc i edit-fn | (values document (or/c #f edit-change))（**唯一的编辑入口**；`#f` = no-op/被拒；`edit-change` = desc + 逆（用**编辑前** buffer 求出）+ 编辑前光标；**不记历史**） |
| `document-apply-descs-trusted` | doc i descs [pre-point] | document（依次施加 descs，**跳过守卫**；给了 `pre-point` 就把视图 i 的光标放回那里并 `ensure-point`。撤销/重放**唯一**的落回入口） |

两条 rebase 模式是**容器语义**（类比 `window.mode` 的 `'clip`/`'wrap`）：

- **`'free`**：别人编辑后，我的**光标随文本映射**（落在被删区间 → 吸附起点），**视口不动**。
  正确性下限：光标不会指向别的文本，参考视图也不会因别处编辑而漂移。
- **`'follow`**：我的**光标 + 视口锚点复制自编辑视图**，然后**按我自己的几何
  `window-ensure-point`**。几何（与 mode）相同 → 与编辑视图 lockstep；不同 → 跟着光标、
  视口自己夹紧，不会把光标丢到自己可见区之外。

正在被编辑的那个视图（`i`）总是「光标推进到插入后 + `ensure-point`」。

**第三种策略**：编辑前用 `document-window` 取到旧 window（不可变快照），编辑后用
`document-update-view` 任意调整即可——不需要把策略做成函数塞进 core。

---

## 7. 数据流（怎么串起来）

### 7.1 编辑闭环

```racket
(define-values (doc _) (document-add-view (document-open "hello\nworld") 10 40))

;; 一个 text-event 进来：
(define-values (doc* ch) (document-edit doc 0 (edit-insert-char #\X)))
;;   doc* : buffer 已换新、point 已推到编辑后位置（document-edit 自动做）
;;   ch   : (or/c #f edit-change)；#f = 什么都没发生。要撤销就收下它。
;;          document-edit 是**唯一**编辑入口——单窗口就是「一个视图的 document」。
```

### 7.2 渲染链

```racket
(define s (window->screen w))       ; buffer → glyph → run → screen
;; 多窗口/状态行：
(define big (screen-compose rows cols
              (list (list 'buf 0 0 (window->screen w1))
                    (list 'status 0 area-h (status-screen)))
              'buf))
```

### 7.3 属性链（写一次，全自动）

```racket
(define b2 (buffer-put-property b 0 1 7 'face 'keyword))
;; 编辑时属性跟着文本走（edit-desc 契约）
;; window->screen 时属性变 run.face
;; 后端 (hash-ref (run-face r) 'face) → 主题 → 颜色
```

### 7.4 输入路由（使用方的职责）

```racket
;; 鼠标 (x,y) 是屏幕坐标，要三步变 buffer 坐标：
;; 1) 命中哪个窗口？（布局知识）
;; 2) (x - win.x, y - win.y) 减偏移
;; 3) window-screen->point w row col → (line col)
```

### 7.5 read-only 区域（显示 + 输入）

read-only 是**约束槽**（`restrict`，typed）里的语义，不是表现层属性：它由 core 解释
（编辑守卫），不进 `screen` 的 `run.face`——要给它配色，另写一个表现层键即可。

```racket
(define b  (buffer-open "> _"))
(define b1 (buffer-put-restrict  b  0 0 2 (restrict #t)))   ; "> " 不可编辑
(define b2 (buffer-put-property  b1 0 0 2 'face 'prompt))   ; 顺带提示色
(define w  (window-set-point (window-open b2 1 40) (point 0 3)))  ; 光标放输入区

;; 打字在输入区（col 3）→ 允许；打字在提示区（col 0~1）→ 拒绝（no-op）
;; backspace 到边界 → 拒绝（不能删进提示区）
```

规则：零宽插入在 read-only 区间「内部」→ 拒绝，在边界 → 允许；
非零宽删除与 read-only 区间「重叠」→ 拒绝。

read-only 区间是**硬边界**：在它的边界插入，两个槽都**不继承**（新输入既不带约束，
也不带提示色）。两个槽彼此独立：写约束不影响表现层，反之亦然。

**程序要编辑 read-only 内容**：走**显式入口** `buffer-splice-trusted`（没有全局开关）：

```racket
(buffer-splice-trusted b 0 2 0 2 "X")   ; 在 read-only 区间内插入一个字符
```

注意：它只绕过编辑守卫，不改变硬边界继承——程序编辑 read-only 内容后，
新增部分若要继续 read-only，需自行重新标记（这本来就是构造字段的职责）。

---

## 8. 最小编辑器骨架

```racket
(require "core/api.rkt")

(define-values (doc _) (document-add-view (document-open "hello") 24 80))  ; 开文档 + 开视口

;; 每帧：
(define s (window->screen (document-window doc 0)))   ; 投影成画面，后端画 s

;; 后端喂入 event 后：
(define-values (doc* ch) (document-edit doc 0 (edit-insert-char #\X)))  ; 处理 text-event
(define doc2 (document-update-view doc* 0 window-right))          ; 处理 key-event 'right
```

> 命名约定速查：`make-*`（空构造）、`*-open`/`*-of-*`（从数据构造）、`*->*`（投影）、
> `*-set-*`（字段更新）、动词-名词（变换）、`*-apply-edit`（解释 edit-desc）。
>
> **无前端示例**见 `editor.rkt`——一个不碰终端的完整编辑器（打开 / 编辑 / 导航 / 撤销 /
> 高亮 / 只读 / 渲染成纯文本），文件头列出它用到的全部 core 名字。
>
> **撤销账本**在 `history.rkt`（消费层）：`step`/`history`/合并规则，见 ARCHITECTURE §8.5。

---

## 9. 立场：core 不解释的东西

「不做」也是设计的一部分。以下这些 core **明确不解释**，消费方按这里的说法自己处理：

| 立场 | 说明 |
|---|---|
| **tab / Ambiguous 宽度** | core 一律按 **1 列**（`char-display-width #\tab` = 1，`string-display-width` / `index->column` 同口径）。终端把 tab 画成多列是**后端的事**：要对齐就自己先展开成空格 |
| **`modified?` 谁置位** | splice 与属性/约束/marker/overlay 写入都置 `#t`；只有 `buffer-apply-patches`（插件标注）不置 —— 用它判断「有没有未保存改动」时要知道这一点 |
| **没有 `dirty` 槽** | 增量信息**归操作、不归文档**：要「这次/这一步改到哪几行」用 `edits-span`（传一条 desc 或整组）；`buffer-tick` 只回答「有没有变」（ARCHITECTURE §8.7） |
| **`left-col` 大于行宽** | **合法状态**（「滚过短行尾部」，该行显示空），不是错误；但**落在宽字符右半**会被吸附到字符起点 |
| **`modified?` 的回退 / 保存点** | core 不做（`modified?` 只是「约定」，见 ARCHITECTURE §8.5） |
| **撤销 / 重放账本** | 不在 core：core 只给**可逆编辑代数**；账本与分组是消费层策略（ARCHITECTURE §8.5） |
| **命令 / 键位 / 主题 / 布局** | 不在 core（§1.2） |

## 10. 契约与违约行为

core 的契约分两类（完整规则、依据与实测见 ARCHITECTURE §9）：

- **没有唯一合法解释的输入 → 报错**（抛 `exn:fail?`）：编辑区间反向（`s > e`）、属性/约束区间
  为空或反向、视图索引越界、`window-set-mode` 未知 mode、marker/overlay 位置不在 buffer 内、
  overlay 区间反向、patch 行范围越界（过期 patch）。
- **有唯一合法解释的输入 → 夹紧**：越界行列、属性端点超出行长、视口 `top`/`left` 越界
  （经 `document` 的路径自动夹，`window-clamp-view` 供直接摆 window 的消费方手动夹）。

夹紧类的实际结果（含 `edit-desc` 里的坐标）反映**夹紧后**的值——想确认发生了什么，看返回的 `desc`。
