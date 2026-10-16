#lang racket

;;; 30 —— 只有编辑区：world 里没有任何 tree / status，验证 app 与具体 pane 无关
;;;
;;;   racket temp/30-editor-only.rkt          # 直接进 TUI
;;;   racket temp/30-editor-only.rkt check    # headless 自检
;;;
;;; 布局：布局树的根就是一个 leaf（role='editor'，无边框 → 内容铺满全屏）。
;;; 键位：
;;;   C-s ←/→/↑/↓   切分编辑区（仍只有编辑区，只是多块）
;;;   C-s d         关闭焦点：keep-last → 最后一块清空 view 但不删 leaf
;;;   C-q           退出
;;;
;;; 说明：app 层完全不认识 "tree" / "status"。要加它们，只需在 base-layout 里
;;; 多放 pane + 给对应 document 注册 kind；要去掉，删掉即可，ops/step/loop 不动。

(require tui
         "../core/editor.rkt"
         "../edit-tui/theme/main.rkt"
         "../edit-tui/core-render/main.rkt"
         "../edit-tui/command/main.rkt"
         "../edit-tui/layout/main.rkt"
         "../edit-tui/app/main.rkt")

;;; ════════════════ 资源 ════════════════

(define-doc-kind! 'text #:keymaps (list edit-keys motion-keys pointer-keys))

(define res (make-resources))
(define-values (eb eview) (open-document! res "main.rkt"
                                          "(define (f x)\n  (+ x 1))\n\n(f 41)\n"
                                          #:kind 'text))

;;; ════════════════ 布局：根的叶子就是编辑区，无边框铺满 ════════════════

(define (base-layout)
  (pane 'editor #:view eview #:borders '() #:role 'editor))

;;; ════════════════ 命令 ════════════════

(define global-keys
  (keys
   [(key 's 'ctrl) (key 'left)  (λ (ctx) (split-left ctx))]
   [(key 's 'ctrl) (key 'right) (λ (ctx) (split-right ctx))]
   [(key 's 'ctrl) (key 'up)    (λ (ctx) (split-up ctx))]
   [(key 's 'ctrl) (key 'down)  (λ (ctx) (split-down ctx))]
   [(key 's 'ctrl) (key 'd)     (λ (ctx) (close-focused ctx))]
   [(key 'q 'ctrl) (λ (ctx) (quit))]))

(define (make-app-world)
  (make-world #:area (rect 0 0 80 24)
              #:layout (base-layout)
              #:focus (leaf-ref 'editor)
              #:keytable (make-keytable global-keys)))

;;; ════════════════ 入口 ════════════════

(module+ main
  (define args (current-command-line-arguments))
  (if (and (positive? (vector-length args)) (equal? (vector-ref args 0) "check"))
      (run-check!)
      (run-app (make-app-world))))

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

(define (run-check!)
  (set-box! world* (make-app-world))
  (check "布局根就是 1 个编辑区 leaf" (= 1 (length (leaves))))
  (check "role = 'editor" (eq? (leaf-role (car (leaves))) 'editor))
  (check "无边框：内容区 = 全屏"
         (equal? (panel-content (car (world-panels (unbox world*))))
                 (rect 0 0 80 24)))

  (feed! (ctrl 's)) (feed! (plain 'right))
  (check "C-s → 仍只有编辑区（2 块）" (= 2 (length (leaves))))
  (check "新块也是 'editor" (for/and ([l (in-list (leaves))]) (eq? (leaf-role l) 'editor)))
  (feed! (ctrl 's)) (feed! (plain 'down))
  (check "C-s ↓ 再切分（3 块）" (= 3 (length (leaves))))

  (feed! (ctrl 's)) (feed! (plain 'd))
  (check "C-s d：删到 2 块" (= 2 (length (leaves))))
  (feed! (ctrl 's)) (feed! (plain 'd))
  (feed! (ctrl 's)) (feed! (plain 'd))
  (check "关到只剩 1 块（keep-last）" (= 1 (length (leaves))))
  (check "最后一块：leaf 保留，view 被清空" (not (leaf-view (car (leaves)))))
  (check "焦点仍在编辑区" (splittable-leaf? (car (leaves))))

  (displayln "editor-only: 自检 OK"))
