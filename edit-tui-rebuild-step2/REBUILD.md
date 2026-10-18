# edit-tui-rebuild —— 相对 `edit-tui/` 的重构台帐

> 目标：**以 `edit-tui/` 为参考实现**，把“同一件事的第二条路”和“交互 / 流程 / 贡献 / 面板
> 四样东西没有一等公民”收敛掉。
>
> 纪律：
> 1. 每一步都独立可跑：`bash test/run.sh` 全绿才进下一步；
> 2. 只删影子实现、只补缺的原语，不为了对称加 API（新 API 必须有调用者）；
> 3. 每步在本文件记「改了什么 / 为什么 / 怎么验证」。

## 审查结论（三块）

| 块 | 现状 | 结论 |
|---|---|---|
| A 核心数据 `document / view / panel` | 真身 / 镜像分离、写口单一、slot 通用 | 数据模型对；别扭在“同一件事的第二条路”（状态栏两条渲染、写文本两个入口、effect 两个解释器、layout 六处解树、焦点四处解析） |
| B 状态 `state / 命令 / layout` | State 只存 id+元数据、结构与几何分离、命令=数据+ctx | 缺“交互 / 流程”的一等公民：进行中的交互有 7 个家、取消有 5 条路、流程状态藏在 effect 闭包里 |
| C 插件 / hook | 插件=数据、装配=纯 fold、6 张注册表 | 缺 owner（不能拆 / 不能 reload / 冲突静默）、`panel-spec` 是半描述符、异步三件套逐插件复制、浮层旁路 panel 模型 |

## 进度

| # | 步骤 | 状态 |
|---|---|---|
| 1 | layout 不再静默失败（`tree-insert/tree-split` → `(values tree ok?)`、`empty-tree?`） | ✅ |
| 2 | input session 带身份（`input-session{tag,data,cancel,prompt}`，不再用 prompt 正则认亲） | ✅ |
| 3 | `validate-env` 装配期校验（keymap 叶子 / scope / layer / part 名） | ✅（`validate-environment`） |
| 4 | view / region 消失时浮层跟着消失 | ✅ |
| 5 | 删 chrome 的第二条渲染通道（`chrome-entry` / `chrome-line` / `chrome-member`） | ✅ |
| 6 | `toggle-region!` 原语（hide/show + 尺寸记忆 + 焦点回退） | ✅ |
| 7 | `panel-spec` 加 `key / install / hint / placement`，统一 `install-panel!` | ✅ |
| 8 | `interaction` 栈（`state.pending` LIFO + `env.interactions` 取消） | ✅ |
| 9 | `query-effect` + `service` 模块声明（取代插件里的 cache/pending/job 三件套） | ✅（`model/service.rkt` + `service-request` + `query-effect` + `env/service.rkt`） |
| 10 | env provenance + `plugin-uninstall!` | ✅（env 撤销 + store + panel） |
| 11 | `project-frame` 只用一次 + `layout-snapshot` | ✅（`render-frame*` + `geometry-snapshot`） |
| 12 | effect 的 `k` → 数据 continuation | ⬜ |

---

## 1. layout 不再静默失败 ✅

**改了什么**

- `model/layout.rkt`
  - `tree-insert` / `tree-split` → `(values 新树 inserted?)`；`inserted? = #f` 表示 target 不在树里，树原样返回。
  - 新增 `empty-tree?`（不再靠 `(pair? (split-children …))` 探针）。
  - `tree-move` 接住 `inserted?`。
- `bootstrap/commands/view.rkt` `mount-split`：不再“先登记 region 再切”，而是**先切、失败就报错**（`split: source region has no layout leaf`）。
- `plugins/filetree/commands.rkt` `ensure-editor-region`：接住 `ok?`。

**为什么**

以前 `tree-insert` 对不存在的 target 是静默 no-op，而 `mount-split` 已经把 region 写进
`workspace.regions`：结果是「region 登记了、布局里没有」→ 不可见、不可点、焦点能落上去的死状态。
装配错误必须立刻显形。

**验证**：`test/base-model.rkt` 新增 3 条（missing target → `ok? = #f` 且树不变；正常插入 → `#t`；`empty-tree?`）。

## 4. 浮层随 view / region 消失 ✅

**改了什么**

- `model/workspace.rkt`
  - `workspace-remove-view` 丢弃 `float-view = vid` 的浮层；
  - `workspace-remove-region` 丢弃 `float-region = rid` 的浮层；
  - 新增内部 `drop-floats`。

**为什么**

浮层引用的是 view 资源。残留的浮层会让“弹窗还开着”的判断（`completion-open?` 只看
`workspace-float` 是否存在）失真：临时键表摘不掉、上下键被吃掉。锚点失效（anchor view 消失）
则**不**清浮层——那是合法状态（退到左上角）。

**验证**：`test/float.rkt` 新增 4 条（删 view → 清；删 region → 清；删锚点文档 → 保留；删浮层自己的 view → 清）。

## 5. 删掉 chrome 的第二条渲染通道 ✅

**改了什么**

- `projection/render.rkt`：删 `chrome-entry` / `chrome-diff-pieces` / `clear-rect-pieces` / `text-piece`；
  `frame-cache` 只留 `core`；`project-frame` → `(values panels placements)`；`render-frame` 去掉 `#:status-parts`。
- `projection/status.rkt`：删 `chrome-line` / `region-line`（只留 `status-line` / `state-line` / `region-line` 之外的部分）。
- `model/workspace.rkt`：删 `chrome-member` / `chrome-region-member?`；region 成员只有 `view`。
- `runtime/run.rkt`：每帧同步收成一次遍历：
  `environment.panel-syncs` + `state-frame-syncs`（框架自带，**是否装由 `chrome.slot-info` 这个 State 事实决定**）。
- 测试：`test/projection.rkt` 改成“状态栏也是 document”（真 status view + `sync-chrome!` + 正常 panel 渲染）；
  `test/{float,split,save,plugins}.rkt` 适配 2 值 `project-frame`。

**为什么**

生产代码里状态栏一直是真 core view（`install-chrome!` 注册的是 `view-member`），但 `render.rkt`
里还留着 `chrome-member` → 自绘文本 → 清矩形的一整条通道，**只有 `test/projection.rkt` 在构造它**。
两套机制让“改状态栏该改哪儿”无解，而且自绘那条不支持滚动 / 光标 / face。
现在「所有显示都是 document」从**数据**上成立：region 的成员只有 view，渲染只有一条路。

**验证**：`test/projection.rkt` 重写（焦点边框 / 状态栏文本来自 buffer / 消息变化 / resize / 槽消失）；
其余全部测试保持绿。
