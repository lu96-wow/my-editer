#lang racket

;;; 27 —— 交互 demo：顶部文件树 / 中间编辑区 / 底部状态栏
;;;
;;;   racket temp/27-split-demo.rkt          # 直接进 TUI（手动测试）
;;;   racket temp/27-split-demo.rkt check    # headless 自检
;;;
;;; 键位：
;;;   C-b                开 / 关文件树
;;;   C-s ←/→/↑/↓        按方向切分编辑区（产生新的空编辑区，焦点移过去）
;;;   C-w ←/→/↑/↓        在面板间移动焦点
;;;   C-o                往当前编辑区开一个文档
;;;   C-q                退出
;;;
;;; 布局：tree(顶部) / editor(中间, role='editor') / status(底部)。

(require tui
         "../core/editor.rkt"
         "../edit-tui/theme/main.rkt"
         "../edit-tui/core-render/main.rkt"
         "../edit-tui/command/main.rkt"
         "../edit-tui/layout/main.rkt"
         "../edit-tui/app/main.rkt")

;;; ════════════════ 类型 / 资源 ════════════════

(define-doc-kind! 'text     #:keymaps (list edit-keys motion-keys pointer-keys))
(define-doc-kind! 'file-tree #:keymaps (list  pointer-keys))
(define-doc-kind! 'status    #:keymaps '())

(define res (make-resources))
(define-values (tb tview) (open-document! res "*tree*"
                                          "project/\n  src/\n    main.rkt\n    util.rkt\n  README.md\n"
                                          #:kind 'file-tree))
(define-values (eb eview) (open-document! res "main.rkt"
                                          "(define (f x)\n  (+ x 1))\n\n(f 41)\n"
                                          #:kind 'text))
(define-values (sb sview) (open-document! res "*status*"
                                          " NORMAL   split-demo    C-b tree · C-s+←/→/↑/↓ split · C-q quit"
                                          #:kind 'status))

(define W 80) (define H 24)

;; 顶部 tree / 中间编辑区 / 底部 status
(define (base-layout)
  (lay 'tb
       (pane 'tree   #:view tview #:size 1 #:dock 'top)
       (pane 'editor #:view eview #:size 8 #:dock 'center #:role 'editor)
       (pane 'status #:view sview #:size 1 #:borders '())))

;;; ════════════════ 命令 ════════════════

(define (quit) (modify (λ (w) (struct-copy world w [running? #f]))))

(define (focused-editor-id ctx)
  (define r (ctx-ref ctx))
  (and r (eq? (panel-ref-kind r) 'leaf)
       (let ([l (tree-find (world-layout (ctx-world ctx)) (panel-ref-id r))])
         (and (editor-leaf? l) (leaf-id l)))))

(define (open-into-focused ctx)
  (define id (focused-editor-id ctx))
  (if id
      (list (open-doc
             (λ () (open-document! res "untitled" "" #:kind 'text))
             (λ (w b v) (struct-copy world w [layout (tree-set-view (world-layout w) id v)]))))
      '()))

(define global-keys
  (keys
   [(key 'b 'ctrl) (λ (ctx) (toggle-pane 'tree))]
   [(key 's 'ctrl) (key 'left)  (λ (ctx) (split-left ctx))]
   [(key 's 'ctrl) (key 'right) (λ (ctx) (split-right ctx))]
   [(key 's 'ctrl) (key 'up)    (λ (ctx) (split-up ctx))]
   [(key 's 'ctrl) (key 'down)  (λ (ctx) (split-down ctx))]
   [(key 'o 'ctrl) (λ (ctx) (open-into-focused ctx))]
   [(key 'q 'ctrl) (λ (ctx) (list (quit)))]))

(define (make-app-world)
  (make-world #:area (rect 0 0 W H)
              #:layout (base-layout)
              #:focus (leaf-ref 'editor)
              #:keytable (make-keytable global-keys focus-keys)
              #:status "split-demo"))

;;; ════════════════ 入口 ════════════════

(module+ main
  (define args (current-command-line-arguments))
  (if (and (positive? (vector-length args)) (equal? (vector-ref args 0) "check"))
      (run-check!)
      ;; 默认直接进 TUI（手动测试）
      (run-app (make-app-world))))

;;; ════════════════ headless 自检（check） ════════════════

(define world* (box #f))
(define (plain c) (key-event c (mods #f #f #f)))
(define (ctrl c)  (key-event c (mods #t #f #f)))
(define (check label ok?)
  (if ok? (printf "  ✓ ~a\n" label) (error 'check "~a 失败" label)))
(define (feed! ev)
  (define-values (w intents) (world-step* (unbox world*) (list ev)))
  (set-box! world* w) intents)

(define (rect-of id)
  (cadr (assoc id (tree->placements (world-layout (unbox world*)) (world-area (unbox world*))))))
(define (nleaves) (length (tree-leaves (world-layout (unbox world*)))))

(define (run-check!)
  (set-box! world* (make-app-world))
  (define tr (rect-of 'tree)) (define er (rect-of 'editor)) (define sr (rect-of 'status))
  (printf "tree=~a editor=~a status=~a\n" tr er sr)
  (check "tree 在顶部" (= 0 (rect-y tr)))
  (check "editor 在 tree 下方" (> (rect-y er) (rect-y tr)))
  (check "status 在底部（与 editor 共享 1 格接缝）"
         (>= (rect-y sr) (sub1 (+ (rect-y er) (rect-h er)))))

  (feed! (ctrl 'b))
  (check "C-b 关文件树" (not (tree-visible? (world-layout (unbox world*)) 'tree)))
  (feed! (ctrl 'b))
  (check "C-b 开文件树" (tree-visible? (world-layout (unbox world*)) 'tree))

  (define n0 (nleaves))
  (feed! (ctrl 's)) (feed! (plain 'right))
  (check "C-s → 切分编辑区（多一个 leaf）" (= (add1 n0) (nleaves)))
  (feed! (ctrl 's)) (feed! (plain 'down))
  (check "C-s ↓ 再切分" (= (+ n0 2) (nleaves)))

  (displayln "split-demo: 自检 OK"))
