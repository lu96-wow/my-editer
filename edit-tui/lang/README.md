# edit-tui/lang

共享语言能力层。这里不是插件，也不是 core；它是“按语言分目录的纯能力库”。

```text
lang/
  racket/
    api.rkt          唯一对外面
    edit.rkt         语言层 line-edit（旧/新行区间）
    lex.rkt          词法 token（跨行注释 / 字符串）
    highlight.rkt    语法高亮角色
    color.rkt        增量着色缓存（语法 + 同词色）
    word-color.rkt   同词着色角色
    source.rkt       #lang / require / define / provide 扫描
    analysis.rkt     Racket 绑定形式 -> 局部名字（lambda / let / for / match …）
    workspace.rkt    跨 buffer 的解析缓存 + require 依赖
    pool.rkt         require spec -> 绑定名 / 模块导出
    module-index.rkt 已安装模块路径
    completion.rkt   补全候选
    docs.rkt         标准库文档（xref / blueboxes）
    local-docs.rkt   当前缓冲区里的本地定义
    doc-html.rkt     HTML 文档正文兜底
```

## 多语言约定

以后加语言时，照 `racket/` 的形状新增目录，例如：

```text
lang/python/
  api.rkt
  lex.rkt
  highlight.rkt
  word-color.rkt
  completion.rkt
  docs.rkt
```

`api.rkt` 是该语言唯一对外面；编辑器侧不要直接 require 语言内部实现。
语言层不 require `app` / `boot` / `edit-tui/core`，保持纯、可单独测试。

## Racket 四个基础能力

```racket
(require "edit-tui/lang/racket/api.rkt")

;; 1. 语法高亮：每行一个 role 向量
(highlight-text text)          ; -> (listof (vectorof symbol|#f))
(highlight-role text line col)

;; 增量：line-edit + color-state
(color-open text)
(color-edit state text edits)
(color-syntax-roles state)
(color-word-roles state)

;; 2. 同词着色
(word-color-text text)         ; -> (listof (vectorof symbol|#f))
(word-color-index "foo")       ; 稳定整数
(word-color-role "foo")

;; 3. 文档
(docs-for "map" #:modules '(racket/base))   ; -> doc | #f
(doc->text d)
(local-def text 'foobar)

;; 4. 补全
(completion-prefix text line col)
(completion-at path text line col #:open open-texts)
(completion-at path text line col
               #:workspace ws #:id doc-id)
(completion-candidates ctx prefix)
(completion-insert-text candidate prefix)

;; 局部名字：按 Racket 绑定形式收集，而不是扫所有词
(local-binding-names text)
```

跨 buffer 缓存：

```racket
(workspace-set-doc ws doc-id path text #:version v)
(workspace-analysis ws doc-id)          ; 同一版本复用
(workspace-export-names ws doc-id)      ; provide / all-from-out 跨 buffer 展开
(workspace-imported-names ws doc-id)    ; require 带来的名字
(workspace-local-pool ws doc-id)        ; 当前绑定 + 直接 require 的本地 buffer 导出
(workspace-local-def ws doc-id name)    ; 先当前，再依赖，再其它打开 buffer
(docs-local ws doc-id name)
```

## 增量策略

- **着色**：按行缓存词法状态 / 语法 role / 同词 role，`color-edit` 只重扫脏行；
  跨行块注释 / 字符串状态变化时向后推进到收敛。
- **解析**：按顶层 `form-entry` 缓存。`analysis-edit` 只重读受脏行影响的
  form；尾部遇到未变化的旧 form 就收敛，剩余 entry 只平移行号。
- **workspace**：`workspace-apply-changes` 更新单个文档的 analysis；依赖它的
  buffer 不重新 parse，导出查询读取新的接口结果。

参考 `racket-langserver` 的取舍：

- 它的 lexer 不是逐字符增量的，而是 `LexerSnapshot` + lazy cache + 编辑后失效；
- 真正值得借的是“绝对 span / token tree / position journal / 异步结果版本”；
- 这里着色做得更细（行级 change），语义解析则用顶层 form 作为增量单位。

编辑器接入方式后续再做：语言层只产出 role / 候选 / 文档数据，不决定 face、菜单、
弹窗或异步 worker。
