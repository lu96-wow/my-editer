#lang racket

;;; 26 —— 编辑区切分原语：split-left / right / up / down
;;;
;;;   racket temp/26-editor-split.rkt        # headless：验证四个原语
;;;   racket temp/26-editor-split.rkt tui    # 交互
;;;
;;; 模型：
;;;   · 布局 = 面板（role='panel，固定区域，如文件树）+ 编辑区（role='editor）；
;;;   · 编辑区初始可以是**空 panel**（view=#f），用一个空 leaf 占位；
;;;   · 四个切分原语只对**焦点所在的编辑区**生效，产生一个新的空编辑区并把焦点移过去；
;;;   · 对普通面板（role='panel'）不生效（no-op）。
;;;
;;; 键位：C-x h/l/k/j = split-left/right/up/down · C-o 往焦点编辑区开一个文档
;;;       C-w ←/→ 焦点移动 · C-q 退出

(require tui
         "../core/editor.rkt"
         "../edit-tui/theme/main.rkt"
         "../edit-tui/core-render/main.rkt"
         "../edit-tui/command/main.rkt"
         "../edit-tui/layout/main.rkt"
         "../edit-tui/app/main.rkt")

;;; ════════════════ 类型 / 资源 ════════════════

(define-doc-kind! 'text #:keymaps (list edit-keys motion-keys pointer-keys))
(define-doc-kind! 'file-tree #:keymaps '())   ; 文件树暂不给键

(define res (make-resources))
(define-values (tb tview) (open-document! res "*tree*" "src/\n  main.rkt\nREADME.md" #:kind 'file-tree))

(define W 80) (define H 24)

;; 面板（文件树，固定）+ 空编辑区（占位）
(define (base-layout)
  (lay 'lr
       (pane 'tree   #:view tview #:size 2 #:dock 'left)
       (pane 'editor #:view #f    #:size 6 #:dock 'center #:role 'editor)))

;;; ════════════════ 命令 ════════════════

(define (focused-editor-id ctx)
  (define r (ctx-ref ctx))
  (and r (eq? (panel-ref-kind r) 'leaf)
       (let ([l (tree-find (world-layout (ctx-world ctx)) (panel-ref-id r))])
         (and (splittable-leaf? l) (leaf-id l)))))

;; 往焦点编辑区开一个文档（open-doc：不纯创建 + 纯装进该 leaf）。
(define (open-into-focused ctx)
  (define id (focused-editor-id ctx))
  (if id
      (list (open-doc
             (λ () (open-document! res "untitled" "" #:kind 'text))
             (λ (w b v) (struct-copy world w [layout (tree-set-view (world-layout w) id v)]))))
      '()))

(define global-keys
  (keys
   [(key 'x 'ctrl) (key 'h) (λ (ctx) (split-left ctx))]
   [(key 'x 'ctrl) (key 'l) (λ (ctx) (split-right ctx))]
   [(key 'x 'ctrl) (key 'k) (λ (ctx) (split-up ctx))]
   [(key 'x 'ctrl) (key 'j) (λ (ctx) (split-down ctx))]
   [(key 'o 'ctrl) (λ (ctx) (open-into-focused ctx))]
   [(key 'q 'ctrl) (λ (ctx) (quit))]))

(define (make-app-world)
  (make-world #:area (rect 0 0 W H)
              #:layout (base-layout)
              #:focus (leaf-ref 'editor)
              #:keytable (make-keytable global-keys focus-keys)
              #:status "editor-split demo"))

;;; ════════════════ 交互 ════════════════

(module+ main
  (define args (current-command-line-arguments))
  (if (and (positive? (vector-length args)) (equal? (vector-ref args 0) "tui"))
      (run-app (make-app-world))
      (run-check!)))

;;; ════════════════ headless 自检 ════════════════

(define world* (box #f))
(define (plain c) (key-event c (mods #f #f #f)))
(define (ctrl c)  (key-event c (mods #t #f #f)))
(define (check label ok?)
  (if ok? (printf "  ✓ ~a\n" label) (error 'check "~a 失败" label)))
(define (feed! ev)
  (define-values (w intents) (world-step* (unbox world*) (list ev)))
  (set-box! world* w) intents)

(define (leaves) (tree-leaves (world-layout (unbox world*))))
(define (nleaves) (length (leaves)))
(define (role-of id) (leaf-role (tree-find (world-layout (unbox world*)) id)))
(define (view-of id) (leaf-view (tree-find (world-layout (unbox world*)) id)))
(define (focused-id) (panel-ref-id (world-focus (unbox world*))))

(define (run-check!)
  (set-box! world* (make-app-world))
  (printf "初始 leaf：~a\n" (map leaf-id (leaves)))
  (check "初始 2 个 leaf（tree + editor）" (= 2 (nleaves)))
  (check "编辑区初始为空（view=#f）" (not (view-of 'editor)))
  (check "编辑区 role='editor" (eq? (role-of 'editor) 'editor))
  (check "文件树 role='panel" (eq? (role-of 'tree) 'panel))

  ;; 焦点在编辑区：split-right 产生新空编辑区，焦点移过去
  (feed! (ctrl 'x)) (feed! (plain 'l))
  (check "split-right：多一个 leaf" (= 3 (nleaves)))
  (define e2 (focused-id))
  (check "split-right：新 leaf 是空编辑区"
         (and (eq? (role-of e2) 'editor) (not (view-of e2))))
  (check "split-right：焦点在新编辑区"
         (not (equal? (world-focus (unbox world*)) (leaf-ref 'editor))))

  ;; 继续在焦点编辑区上 split-down
  (feed! (ctrl 'x)) (feed! (plain 'j))
  (check "split-down：再多一个 leaf" (= 4 (nleaves)))

  ;; 对普通面板不生效
  (set-box! world* (struct-copy world (unbox world*) [focus (leaf-ref 'tree)]))
  (feed! (ctrl 'x)) (feed! (plain 'l))
  (check "对面板 split 不生效（leaf 数不变）" (= 4 (nleaves)))
  (check "对面板 split 不生效（无新编辑区）"
         (= 3 (length (filter (λ (l) (eq? (leaf-role l) 'editor)) (leaves)))))

  ;; 往焦点编辑区开一个文档（open-doc 是不纯创建，headless 里手动跑解释：make 造 + f 装）
  (set-box! world* (struct-copy world (unbox world*) [focus (leaf-ref e2)]))
  (define intents (feed! (ctrl 'o)))
  (define od (for/first ([i (in-list intents)] #:when (open-doc? i)) i))
  (when od
    (define-values (b v) ((open-doc-make od)))
    (set-box! world* ((open-doc-f od) (unbox world*) b v)))
  (check "open-into-focused：焦点的空编辑区装上 document"
         (and (view? (view-of e2)) (eq? (view-kind (view-of e2)) 'text)))

  (displayln "editor-split demo: 自检 OK"))
