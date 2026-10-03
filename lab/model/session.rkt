#lang racket

;;; lab/model/session.rkt —— 会话：core editor 值 + lab 侧 delta
;;;
;;;   editor       : core editor 值（documents / views / clipboard 的单一事实源）
;;;   docs         : hash did -> doc-meta（文件信息 + 每文档命令表）
;;;   main         : 主编辑区分屏树
;;;   tree-vids    : [文件树 vid, 文档树 vid]（两棵树视图的身份）
;;;   trees        : (listof tree) 树模型（files / documents）—— 类型由 model/tree 定义
;;;   sidebar-kind : 侧栏当前显示哪棵树（'files | 'documents）
;;;   active       : 焦点 pane-id / #f
;;;   prompt       : #f | (prompt label text on-confirm) —— 输入行状态
;;;   rows/cols    : 当前屏幕格数
;;;
;;; 侧栏是**单个** pane（显示 sidebar-kind 对应的那棵树）；底部固定 1 行状态栏（pane-id 'status）。
;;; **document 与 view 生命周期独立**：关 view 永远不动 document；关 document 才级联其 view。

(require
 "layout.rkt"
 "../../core/editor.rkt")

(provide
 ;; ---------- 类型（含访问器） ----------
 (struct-out doc-meta)
 (struct-out session)
 (struct-out prompt)

 ;; ---------- 构造 ----------
 session-open
 session-blank

 ;; ---------- 结构操作（返回新 session） ----------
 session-open-document
 session-new-view
 session-split-view
 session-close-view
 session-close-document

 ;; ---------- 焦点 / 尺寸 / 布局 ----------
 session-focus
 session-toggle-file-tree
 session-resize
 session-layout
 session-sidebar
 session-rects
 session-apply-layout!
 session-normalize-focus

 ;; ---------- lab 侧字段写口 ----------
 session-set-trees
 session-set-tree-vids
 session-set-sidebar-kind
 session-set-prompt)

;;; ---------- 数据 ----------

(struct doc-meta (path saved-doc commands) #:transparent)
;; path / saved-doc / commands（commands 类型由命令层定义，本层不透明）

;; 输入行：label 前缀 + 已输入文本 + 回车回调 (session → string → session)。
(struct prompt (label text on-confirm) #:transparent)

(struct session
  (editor docs main tree-vids trees sidebar-kind active prompt
   sidebar-hidden? sidebar-width rows cols project)
  #:transparent)

(define default-view-width 80)
(define default-view-height 24)
(define default-sidebar-width 30)

;;; ---------- 构造 ----------

;; 只建主编辑区（scratch）；两棵树由 model/tree 的 trees-init 追加。
(define (session-open text width height [name "*scratch*"])
  (define ed (editor-open text width height name))
  (define doc (document-entry-document (editor-document-entry ed 0)))
  (session ed
           (hash 0 (doc-meta #f doc #f))
           (view-pane 0)
           '()                    ; tree-vids
           '()                    ; trees
           'files                 ; sidebar-kind
           0                      ; active
           #f                     ; prompt
           #f                     ; sidebar 可见
           default-sidebar-width
           height width
           #f))                   ; project

;; 空白会话：**不打开任何编辑器文档**（默认行为）；两棵树由 trees-init 追加。
;; core 没有「空 editor」构造函数，所以先开一个再关掉它。
(define (session-blank width height [project #f])
  (define ed (editor-close-document (editor-open "" width height "*scratch*") 0))
  (session ed
           (hash)                 ; docs
           '()                    ; main
           '()                    ; tree-vids
           '()                    ; trees
           'files                 ; sidebar-kind
           #f                     ; active
           #f                     ; prompt
           #f                     ; sidebar 可见
           default-sidebar-width
           height width
           project))

;;; ---------- 结构操作 ----------

(define (session-open-document s text [name "*scratch*"])
  (define ed (session-editor s))
  (define-values (ed* did vid)
    (editor-add-document-view ed text default-view-width default-view-height name))
  (define doc (document-entry-document (editor-document-entry ed* did)))
  (values (struct-copy session s
            [editor ed*]
            [docs (hash-set (session-docs s) did (doc-meta #f doc #f))]
            [main (layout-append (session-main s) (view-pane vid))]
            [active vid])
          did vid))

(define (session-new-view s did)
  (define ed (session-editor s))
  (define-values (ed* vid)
    (editor-add-view ed did default-view-width default-view-height))
  (values (struct-copy session s
            [editor ed*]
            [main (layout-append (session-main s) (view-pane vid))]
            [active vid])
          vid))

(define (session-split-view s did dir anchor-id)
  (define ed (session-editor s))
  (define-values (ed* vid)
    (editor-add-view ed did default-view-width default-view-height))
  (values (struct-copy session s
            [editor ed*]
            [main (layout-split-pane (session-main s) anchor-id dir (pane vid (view-ref vid)))]
            [active vid])
          vid))

(define (session-close-view s vid)
  (session-normalize-focus
   (struct-copy session s
     [editor (editor-close-view (session-editor s) vid)]
     [main (layout-remove (session-main s) vid)])))

(define (session-close-document s did)
  (define vids
    (for/list ([v (in-list (editor-views (session-editor s)))]
               #:when (= did (view-did v)))
      (view-id v)))
  (define s1 (for/fold ([s s]) ([vid (in-list vids)]) (session-close-view s vid)))
  (session-normalize-focus
   (struct-copy session s1
     [editor (editor-close-document (session-editor s1) did)]
     [docs (hash-remove (session-docs s1) did)])))

;;; ---------- 焦点 / 尺寸 / 布局 ----------

(define (session-focus s id) (struct-copy session s [active id]))
(define (session-toggle-file-tree s)
  (struct-copy session s [sidebar-hidden? (not (session-sidebar-hidden? s))]))
(define (session-resize s rows cols)
  (struct-copy session s [rows (max 1 rows)] [cols (max 1 cols)]))

(define (session-set-trees s ts) (struct-copy session s [trees ts]))
(define (session-set-tree-vids s vs) (struct-copy session s [tree-vids vs]))
(define (session-set-sidebar-kind s k) (struct-copy session s [sidebar-kind k]))
(define (session-set-prompt s p) (struct-copy session s [prompt p]))

;; 侧栏：**单个** pane，显示 sidebar-kind 对应的树视图（tree-vids = [files, documents]）。
(define (session-sidebar s)
  (define vids (session-tree-vids s))
  (define v (cond [(eq? (session-sidebar-kind s) 'files) (and (pair? vids) (car vids))]
                   [else (and (pair? vids) (pair? (cdr vids)) (cadr vids))]))
  (if v (view-pane v) '()))

;; 整棵树：侧栏 + 主区，底部固定 1 行状态栏。
(define (session-layout s)
  (define m (session-main s))
  (define sb (and (not (session-sidebar-hidden? s)) (session-sidebar s)))
  (define workspace
    (cond
      [(and (null? m) (not sb)) '()]
      [(null? m) sb]
      [(not sb) m]
      [else (split 'row (list sb m)
                   (list (fixed (session-sidebar-width s)) (flex 1)))]))
  (split 'col (list workspace (leaf (pane 'status 'status)))
         (list (flex 1) (fixed 1))))

(define (session-rects s)
  (layout-rects (session-layout s) 0 0 (session-cols s) (session-rows s) 1 (lambda (_) #t)))

(define (session-apply-layout! s)
  (editor-set-layout
   (session-editor s)
   (for/list ([r (in-list (session-rects s))]
              #:unless (eq? (pane-rect-id r) 'status))
     (rect (pane-rect-id r) (pane-rect-x r) (pane-rect-y r)
           (pane-rect-w r) (pane-rect-h r) 0)))
  s)

;; active 若不存在 → 第一个非 status 叶子；没有 → #f。
(define (session-normalize-focus s)
  (define ids (for/list ([id (layout-ids (session-layout s))]
                         #:unless (eq? id 'status))
                id))
  (cond
    [(and (session-active s) (member (session-active s) ids)) s]
    [else (struct-copy session s [active (cond [(pair? ids) (car ids)] [else #f])])]))
