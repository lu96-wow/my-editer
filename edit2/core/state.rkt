#lang racket

;;; edit2/state.rkt —— 唯一状态 + 值类型
;;;
;;; State 只有 7 个字段。几何、可见集合、脏标志… 全是派生，永不存。
;;; 布局树是「用户意图」，不是几何。
;;;
;;; ed ：core 编辑器句柄（命令式引擎，box 是设计；线性穿过，不进 State 语义）
;;; docs：did -> doc-meta（路径 / 存档句柄），文本真身在 core
;;; views：vid -> hash（特性局部状态）

(provide
 (struct-out doc-meta)
 (struct-out blank)
 (struct-out empty-area)
 (struct-out main)
 (struct-out pane)
 (struct-out split)
 (struct-out float)
 (struct-out anchor)
 (struct-out state)
 (struct-out job)
 (struct-out prompt)
 (struct-out placing)
 make-state feature-ref feature-set)

(require "../../core/editor.rkt")

;; doc-meta
;;   path  : path | #f
;;   saved : 存档时的 core document 句柄（eq? 比较出脏）
(struct doc-meta (path saved) #:transparent)

;;; ---------- 布局树：用户意图 ----------

(struct anchor (rel h v dx dy) #:transparent)
;; rel : vid | #f（屏幕）
;; h   : 'left | 'right | 'center | 'stretch
;; v   : 'top  | 'bottom | 'center | 'stretch

(struct blank () #:transparent)
;; 持久空位：编辑区没有视图时留在原位，不让父 split 塌缩（如状态栏被顶到顶上）。
(struct empty-area () #:transparent)
;; 主区：区域（sidebar/log…）往这里贴，而不是裹住整个根。
;; 于是状态栏可以是根的最外层底栏（全宽），侧栏只占它上方。
(struct main (tree) #:transparent)
;; pane / float：窗口有自己的身份 wid，并引用一个视图 vid。
;; 同一个 vid 可以出现在多个 wid（同 view 多位置）；焦点 / 浮窗栈 / 命中都用 wid。
;; border = #f（无边框）| 命名 face（如 'window-border）。
(struct pane (wid vid border) #:transparent)
;; parts : (list (cons size Layout))，size = 整数格数 | 'flex
(struct split (axis parts) #:transparent)
(struct float (wid vid border anchor want-w want-h) #:transparent)

;;; ---------- 唯一状态 ----------
;; focus : wid（窗口身份，不是 vid）；stack : (listof wid)
;; 输入行 / 前缀不存在 State：提示词正文在 *input* 文档，元数据在 feature（见下）。
(struct state (ed docs views layout focus stack jobs) #:transparent)

(define (make-state #:ed [ed (make-blank-editor)]
                    #:docs [docs (hash)]
                    #:views [views (hash)]
                    #:layout [layout (blank)]
                    #:focus [focus #f]
                    #:stack [stack '()]
                    #:jobs [jobs (hash)])
  (state ed docs views layout focus stack jobs))

;;; ---------- 特性局部状态（存在 views 里，不新增全局字段） ----------

(define (feature-ref st k d) (hash-ref (state-views st) k d))
(define (feature-set st k v)
  (struct-copy state st [views (hash-set (state-views st) k v)]))

;;; ---------- 后台任务 ----------

(struct job (id kind key input) #:transparent)

;;; ---------- 输入行（数据化：kind 决定提交时的行为） ----------
;;
;; 正文在 *input* 文档（一切皆 document）；打开时该文档**就地占用状态栏 pane**
;; （把状态栏 pane 的 vid 换成 *input*），所以输入行与状态栏同一位置、同一几何。
;; 存在 feature 'prompt；不新增 State 字段。
(struct prompt (wid label kind data prev-focus) #:transparent)
;; wid        : 被换 vid 的那个 pane（即状态栏 wid），关闭时恢复
;; label      : 文档开头的只读前缀（提交时按它截掉）
;; kind       : 'quit | 'close-doc | 'new-file | 'new-dir | 'delete …
;; data       : kind 相关（close-doc: (list did)；quit: (listof did) 尚未问的）
;; prev-focus : 打开前的焦点 wid（关闭时恢复）

;;; ---------- 放置选择（打开时多窗口 → 用户选目标窗格） ----------

(struct placing (vid prev-focus) #:transparent)
;; vid        : 待放入的视图资源
;; prev-focus : 进入前的焦点（取消时恢复）
;; 候选编辑窗格不存：每次从 layout 现算，布局变了也不会拿到失效 vid。

;; 存在 feature 'placing；不新增 State 字段。

