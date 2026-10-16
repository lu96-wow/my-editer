#lang racket

;;; 25 —— app/ops 原语层 demo：布局 / 焦点 全部用命名原语操作
;;;
;;;   racket temp/25-ops.rkt         # headless：验证各原语
;;;   racket temp/25-ops.rkt tui     # 交互
;;;
;;; 覆盖：
;;;   · 布局：toggle-pane / split-pane / delete-pane / mount-view
;;;   · 浮窗：add-float / remove-float
;;;   · 焦点：focus-keys（focus-move）+ 直接 focus-on
;;;   · 命令里不再出现 struct-copy / tree-* / modify(lambda) 的样板。
;;;
;;; 键位：C-w ←/→ 焦点移动 · C-b 开关 tree · C-s 切分 · C-d 关闭
;;;       C-m 把另一份 document 装进 tree · C-p/C-o 加/删浮窗 · C-q 退出

(require tui
         "../core/editor.rkt"
         "../edit-tui/theme/main.rkt"
         "../edit-tui/core-render/main.rkt"
         "../edit-tui/command/main.rkt"
         "../edit-tui/layout/main.rkt"
         "../edit-tui/app/main.rkt")

;;; ════════════════ 类型 / 资源 ════════════════

(define-doc-kind! 'text #:keymaps (list edit-keys motion-keys pointer-keys))

(define tree-keys
  (keys [(key 'enter) (λ (ctx) (list (modify (λ (w) (struct-copy world w [status "tree: open"])))))]))
(define-doc-kind! 'file-tree #:keymaps (list tree-keys))

(define res (make-resources))
(define-values (eb eview)  (open-document! res "main.rkt"  "(define (f x)\n  (+ x 1))\n\n(f 41)\n" #:kind 'text))
(define-values (tb tview)  (open-document! res "*tree*"    "src/\n  main.rkt\nREADME.md"             #:kind 'file-tree))
(define-values (_ eview2)  (open-document! res "other.rkt" "another document\n"                      #:kind 'text))

(define W 80) (define H 24)
(define (base-layout)
  (lay 'lr
       (pane 'tree   #:view tview #:size 3 #:dock 'left)
       (pane 'editor #:view eview #:size 5 #:dock 'center)))

;;; ════════════════ 命令（全部用 ops 原语，无 struct-copy 样板） ════════════════

(define (focused-leaf-id ctx)
  (define r (ctx-ref ctx))
  (and r (eq? (panel-ref-kind r) 'leaf) (panel-ref-id r)))

(define global-keys
  (keys
   [(key 'b 'ctrl) (λ (ctx) (toggle-pane 'tree))]
   [(key 's 'ctrl) (λ (ctx) (define id (focused-leaf-id ctx))
                           (if id (split-pane id 'lr 'extra) '()))]
   [(key 'd 'ctrl) (λ (ctx) (define id (focused-leaf-id ctx))
                           (if id (delete-pane id) '()))]
   [(key 'm 'ctrl) (λ (ctx) (mount-view 'tree eview2))]
   [(key 'p 'ctrl) (λ (ctx) (add-float (make-float 'demo #f
                                                   (float-rect-at 3 5 20 4 (world-area (ctx-world ctx))))))]
   [(key 'o 'ctrl) (λ (ctx) (remove-float 'demo))]
   [(key 'q 'ctrl) (λ (ctx) (quit))]))

(define (make-app-world)
  (make-world #:area (rect 0 0 W H)
              #:layout (base-layout)
              #:focus (leaf-ref 'editor)
              #:keytable (make-keytable global-keys focus-keys)
              #:status "ops demo"))

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
  (set-box! world* w)
  (printf "  >> ~a\n" (map intent-kind intents))
  intents)

(define (placements) (tree->placements (world-layout (unbox world*)) (world-area (unbox world*))))
(define (nleaves) (length (placements)))

(define (run-check!)
  (set-box! world* (make-app-world))
  (printf "初始 leaf：~a\n" (map car (placements)))
  (check "初始 2 个 leaf" (= 2 (nleaves)))

  ;; 布局：toggle-pane
  (feed! (ctrl 'b))
  (check "C-b 隐藏 tree" (not (tree-visible? (world-layout (unbox world*)) 'tree)))
  (feed! (ctrl 'b))
  (check "C-b 显示 tree" (tree-visible? (world-layout (unbox world*)) 'tree))

  ;; 焦点：focus-keys（C-w → 走 ops/focus-move）
  (set-box! world* (struct-copy world (unbox world*) [focus (leaf-ref 'tree)]))
  (feed! (ctrl 'w)) (feed! (plain 'right))
  (check "C-w → 焦点到 editor" (equal? (world-focus (unbox world*)) (leaf-ref 'editor)))

  ;; 布局：split-pane
  (feed! (ctrl 's))
  (check "C-s 新增 leaf 'extra" (and (tree-contains? (world-layout (unbox world*)) 'extra)
                                     (= 3 (nleaves))))

  ;; 布局：mount-view（把另一份 document 的 view 装进 tree 叶子）
  (feed! (ctrl 'm))
  (check "C-m 把 eview2 装进 tree" (eq? (world-ref->view (unbox world*) (leaf-ref 'tree)) eview2))

  ;; 浮窗：add-float / remove-float
  (feed! (ctrl 'p))
  (check "C-p 加浮窗" (= 1 (length (world-floats (unbox world*)))))
  (feed! (ctrl 'o))
  (check "C-o 移除浮窗" (null? (world-floats (unbox world*))))

  ;; 布局：delete-pane
  (set-box! world* (struct-copy world (unbox world*) [focus (leaf-ref 'extra)]))
  (feed! (ctrl 'd))
  (check "C-d 关闭 focused leaf 'extra"
         (not (tree-contains? (world-layout (unbox world*)) 'extra)))

  (displayln "ops demo: 自检 OK"))
