#lang racket

;;; ============================================================================
;;; shell.rkt —— 壳：布局 + 焦点 + 输入路由 + 渲染
;;; ============================================================================
;;;
;;; 壳是「编排者」，不是「业务」。它只做三件事，且全部由**数据**驱动：
;;;
;;;   1) 路由：把输入交给命中的 pane 自己的 input / pointer；
;;;   2) 焦点：ctrl-o 在可聚焦 pane 间循环、鼠标点谁谁获焦；
;;;   3) 渲染：投影状态栏 → layout 解析成 rects → core 渲染。
;;;
;;; 数据在哪：
;;;   panes   pane-id → pane（每个 pane 自带 input/pointer/focusable?/state/vid）
;;;   layout  布局值（叶 = pane-id）
;;; 所以壳里**没有** tree/editor/status 的分支：pane 的行为就是它自己的 lambda。
;;; 加一个编辑格 = panes 加一项 + layout 加一个叶，这个文件不用改。
;;;
;;; 输入的输出约定：所有 handle 都返回新的 app（不可变值）。
;;; 渲染返回 (app, screen)：app 里带上了本帧的布局尺寸与状态栏内容。

(require "../core/editor.rkt"
         "../core/text/document.rkt"
         "app.rkt"
         "layout.rkt"
         "tree.rkt"
         "buffer.rkt"
         "status.rkt"
         "input.rkt")

(provide setup handle render focus-toggle?)

;;; ============================================================================
;;; 组装：建视图、建 pane 表、建布局
;;; ============================================================================

;; 初始布局：左树(30) | 编辑格 | 底状态栏(1 行)。
(define (setup root rows cols)
  (define ch (max 1 (sub1 rows)))
  ;; core 层的视图
  (define ed0 (editor-open "" 40 ch #:line-numbers? #t))                        ; 编辑格初始视图 = vid0 / did0
  (define-values (ed1 _tdid tvid) (editor-add-document-view ed0 "" 30 ch "*tree*" #:line-numbers? #f))
  (define-values (ed2 _sdid svid) (editor-add-document-view ed1 "" cols 1 "*status*" #:line-numbers? #f))
  ;; pane 表：每个 pane 自带行为（input/pointer）与状态
  (define panes (hash 0 (pane 'tree tvid (tree-open root) tree-input tree-pointer #t)
                      1 (pane 'editor 0 #f buffer-input buffer-pointer #t)
                      2 (pane 'status svid #f #f #f #f)))
  (define layout (vsplit-bottom 1 (hsplit-left 30 (lpane 0) (lpane 1) 1) (lpane 2)))
  (define a (app ed2 (hash) panes layout 1 1 rows cols))                        ; 初始焦点 = 编辑格
  (tree-project! a 0))                                                          ; 树的文档一开始就投影好

;; 按类别找 pane（比如状态栏）。将来多种 pane 时可扩展。
(define (pid-of-kind a kind)
  (for/first ([(id p) (in-hash (app-panes a))] #:when (eq? (pane-kind p) kind)) id))

;; 设焦点；若落在编辑格，同时记成"打开文件的目标格"。
(define (focus-set a pid)
  (define p (app-pane a pid))
  (struct-copy app a [focus pid]
               [editor-pane (if (eq? (pane-kind p) 'editor) pid (app-editor-pane a))]))

;;; ============================================================================
;;; 焦点切换（壳唯一的"业务"）
;;; ============================================================================

(define (focus-toggle-key? k)
  (and (key? k) (key-ctrl? k) (not (key-alt? k)) (not (key-meta? k)) (eqv? (key-name k) #\o)))

(define (focus-toggle? in) (and (key? in) (focus-toggle-key? in)))

;; 在可聚焦 pane（layout 深度优先顺序）里循环到下一个。
;; 多于两格、或换了布局，都不用改这里。
(define (focus-cycle a)
  (define leaves (filter (lambda (pid) (pane-focusable? (app-pane a pid)))
                         (layout-leaves (app-layout a))))
  (define cur (app-focus a))
  (define next
    (let loop ([l leaves])
      (cond [(null? l) cur]
            [(= (car l) cur) (if (null? (cdr l)) (car leaves) (cadr l))]
            [else (loop (cdr l))])))
  (focus-set a next))

;;; ============================================================================
;;; 输入路由
;;; ============================================================================

(define (handle a in)
  (define a1 (handle* a in))
  ;; 开/关文件会改 opened → 让树重新投影，已打开文件的颜色立刻更新。
  (if (equal? (app-opened a) (app-opened a1))
      a1
      (tree-project! a1 (pid-of-kind a1 'tree))))

(define (handle* a in)
  (cond
    ;; 尺寸
    [(resize? in) (struct-copy app a [rows (resize-rows in)] [cols (resize-cols in)])]

    ;; 焦点循环
    [(focus-toggle? in) (focus-cycle a)]

    ;; 鼠标：layout 命中 → pane-id → 点谁谁获焦 → 交局部坐标给该 pane
    [(pointer? in)
     (define pid (layout-hit (app-layout a) (app-cols a) (app-rows a)
                             (pointer-row in) (pointer-col in)))
     (cond
       [(not pid) a]
       [else
        (define p (app-pane a pid))
        (define a1 (if (pane-focusable? p) (focus-set a pid) a))
        (define f (pane-pointer p))
        (cond
          [(not f) a1]
          [else
           (define r (app-pane-rect a1 pid))
           (f a1 pid in (- (pointer-row in) (lrect-y r)) (- (pointer-col in) (lrect-x r)))])])]

    ;; 键盘 / 文本：交给焦点 pane 自己的 input
    [else
     (define p (app-pane a (app-focus a)))
     (define f (pane-input p))
     (if f (f a (app-focus a) in) a)]))

;;; ============================================================================
;;; 渲染
;;; ============================================================================

(define (render a)
  ;; 1) 状态栏是投影：每帧更新一次
  (define a1 (status-project! a (pid-of-kind a 'status)))
  ;; 2) 布局 → lrect；再把 pane-id 解析成当前 vid，得到 core 的 rect
  (define lrs (layout->rects (app-layout a1) 0 0 (app-cols a1) (app-rows a1)))
  (define rects (for/list ([r (in-list lrs)])
                  (rect (app-pane-vid a1 (lrect-id r)) (lrect-x r) (lrect-y r) (lrect-w r) (lrect-h r))))
  ;; 3) 尺寸落到视图（导航/ensure 用），然后纯渲染
  (define ed (editor-set-layout (app-editor a1) rects))
  (define a2 (struct-copy app a1 [editor ed]))
  (values a2 (editor-render-layout ed rects (app-focus-vid a2) (app-cols a2) (app-rows a2))))

;;; ============================================================================
;;; 测试（headless：喂 input，看 screen）
;;; ============================================================================

(module+ test
  (require rackunit
           "../core/view/base/screen.rkt"
           "../core/text/base/selection.rkt"
           "../core/text/base/point.rkt"
           racket/file)

  (define d (make-temporary-file "rbshell-~a" 'directory))
  (define f (build-path d "a.txt"))
  (display-to-file "hello\nworld\n" f #:exists 'replace)

  (define a0 (setup d 10 60))
  (define-values (_a screen0) (render a0))
  (check-equal? (screen-width screen0) 60)
  (check-equal? (screen-height screen0) 10)
  (check-true (for/or ([rn (in-list (screen-row screen0 0))]) (regexp-match? #rx"rbshell" (run-text rn))))
  (check-true (for/or ([rn (in-list (screen-row screen0 9))]) (eq? (run-face rn) 'status)))

  ;; 焦点在编辑格（pane 1）：打字
  (check-equal? (app-focus a0) 1)
  (define a1 (handle a0 (key #\X #f #f #f #f)))
  (check-equal? (substring (editor-view-string (app-editor a1) (app-pane-vid a1 1)) 0 1) "X")

  ;; ctrl-o 循环到树（pane 0）→ 下移 → 回车打开
  (define a2 (handle a1 (key #\o #t #f #f #f)))
  (check-equal? (app-focus a2) 0)
  (define a3 (handle a2 (key 'down #f #f #f #f)))
  (define a4 (handle a3 (key 'enter #f #f #f #f)))
  (check-equal? (editor-view-string (app-editor a4) (app-pane-vid a4 1)) "hello\nworld\n")
  (check-equal? (app-focus a4) 0)          ; 打开文件不抢焦点，仍在树上

  ;; 点编辑格（屏幕 (1,36) → 局部 (1,5)）：切焦点 + 定位
  (define ap (handle a4 (pointer 'press 'left 1 36 #f #f #f #f)))
  (check-equal? (app-focus ap) 1)
  (define exp (call-with-values
               (lambda () (editor-view-screen-pos->point (app-editor a4) (app-pane-vid a4 1) 1 5))
               cons))
  (check-equal? (list (editor-view-point-line (app-editor ap) (app-pane-vid ap 1))
                      (editor-view-point-col (app-editor ap) (app-pane-vid ap 1)))
                (list (car exp) (cdr exp)))

  ;; 拖拽选区（按下 → 拖动）
  (define ad1 (handle a4 (pointer 'press 'left 0 31 #f #f #f #f)))
  (define ad2 (handle ad1 (pointer 'move #f 1 36 #f #f #f #f)))
  (define sel (selections-primary (editor-view-selections (app-editor ad2) (app-pane-vid ad2 1))))
  (define-values (ss se) (selection-range sel))
  (check-equal? (list (point-line ss) (point-col ss)) '(0 0))
  (check-equal? (point-line se) 1)
  (check-true (> (point-col se) 0))

  ;; 点树（屏幕 (1,5)）：切焦点 + 光标落到第 1 行
  (define at (handle a4 (pointer 'press 'left 1 5 #f #f #f #f)))
  (check-equal? (app-focus at) 0)
  (check-equal? (editor-view-point-line (app-editor at) (app-pane-vid at 0)) 1)

  ;; 打开后树的 face 立即从 tree-file 变 tree-open（第 1 行 = a.txt）
  (check-eq? (document-highlight-at (editor-view-document (app-editor a4) (app-pane-vid a4 0)) 1 4)
             'tree-open)

  ;; 树里新建文件（提示 = 文档里一行）
  (define a7 (handle at (key #\n #f #f #f #f)))
  (check-true (regexp-match? #rx"新建文件" (editor-view-string (app-editor a7) (app-pane-vid a7 0))))
  (define a8 (handle a7 (text "made")))
  (define a9 (handle a8 (key 'enter #f #f #f #f)))
  (check-true (file-exists? (build-path d "made")))
  (check-false (regexp-match? #rx"新建文件" (editor-view-string (app-editor a9) (app-pane-vid a9 0))))

  ;; 状态栏始终显示编辑格文档的信息（焦点在树上也不写"文件树"）
  (define-values (a10 screen10) (render a9))
  (check-true (for/or ([rn (in-list (screen-row screen10 9))]) (regexp-match? #rx"a.txt" (run-text rn))))

  ;; resize
  (define a11 (handle a10 (resize 14 40)))
  (define-values (_a12 screen12) (render a11))
  (check-equal? (screen-width screen12) 40)
  (check-equal? (screen-height screen12) 14)

  (delete-directory/files d)
  (displayln "lab-rebuild/shell.rkt: all tests passed"))
