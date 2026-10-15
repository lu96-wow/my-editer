#lang racket

;;; 21 —— 交互式布局 + 鼠标编辑 demo（racket-tui with-tui）
;;;
;;;   racket temp/21-interactive-layout.rkt          # 交互（真终端）
;;;   racket temp/21-interactive-layout.rkt check    # headless 自检
;;;
;;; 能力：
;;;   C-b                文件树 开 / 关（命令层）
;;;   点击编辑区         落光标（panel-at → panel-set-point!）
;;;   拖动编辑区         选区（panel-screen-position->point + selection）
;;;   点击/拖其它面板    焦点切到该面板（tree 也能落光标 / 选）
;;;   滚轮               滚光标所在面板
;;;   拖接缝 / 角拖      改大小（cuts-at → tree-resize-at）
;;;   q / C-x C-c        退出
;;;
;;; 布局来自声明式 spec；运行期只 show/hide + 拖缝。

(require tui
         "../core/editor.rkt"
         "../edit-tui/theme/main.rkt"
         "../edit-tui/core-render/main.rkt"
         "../edit-tui/command/main.rkt"
         "../edit-tui/layout/main.rkt")

;;; ════════════ 状态 ════════════

(define W (box 80))
(define H (box 24))
(define running? (box #t))
(define cache #f)

(define eb (make-buffer "(define (f x)\n  ;; doc\n  (+ x 1))\n\n(f 41)\n" "main.rkt"))
(define ev (buffer-add-view! eb))
(define tb (make-buffer "src/\n  main.rkt\n  util.rkt\n  panel.rkt\nREADME.md" "*tree*"))
(define tv (buffer-add-view! tb))

(define tree (box #f))
(define (base-tree)
  (lay 'lr
       (pane 'tree #:view tv #:size 4 #:dock 'left)
       (lay 'tb
            (pane 'editor #:view ev #:size 3 #:dock 'center)
            (pane 'status #:view #f #:size 1 #:dock 'bottom))))
(set-box! tree (base-tree))

(define focus (box ev))                 ; 焦点 = view（core 的 focus 参数）
(define drag  (box #f))                 ; #f | ('seam 起始 row col cuts 起始树) | ('select panel view anchor)

(define (area) (rect 0 0 (unbox W) (unbox H)))
(define (panels) (tree->panels (unbox tree) (area)))

;;; ════════════ 命令层 ════════════

(define (toggle-tree!)
  (set-box! tree (if (tree-visible? (unbox tree) 'tree)
                     (tree-hide (unbox tree) 'tree)
                     (tree-show (unbox tree) 'tree)))
)

(define keymap
  (keys [(key 'b 'ctrl)          (λ (ctx) (toggle-tree!))]
        [(key 'q)                (λ (ctx) (set-box! running? #f))]
        [(key 'x 'ctrl) (key 'c 'ctrl) (λ (ctx) (set-box! running? #f))]))
(define reader (make-key-reader keymap))

;;; ════════════ 鼠标 ════════════

;; 按下 (row, col)：先看缝（拖大小），否则命中面板 → 焦点 + 落光标 + 起选。
(define (press! row col)
  (define cs (cuts-at (tree->cuts (unbox tree) (area)) row col))
  (cond
    [(pair? cs)
     (set-box! drag (list 'seam row col cs (unbox tree)))]
    [else
     (define p (panel-at (panels) row col))
     (cond
       [(and p (not (panel-empty? p)))
        (set-box! focus (panel-view p))
        (when (panel-set-point! p row col)
          (define-values (l c) (panel-screen-position->point p row col))
          (set-box! drag (list 'select p (panel-view p) (point l c))))]
       [else (set-box! focus #f)])]))

;; 拖动：缝 → 按格数重分；选区 → anchor 固定、head 跟手。
(define (move! row col)
  (define d (unbox drag))
  (when d
    (case (car d)
      [(seam)
       (match-define (list _ r0 c0 cs tree0) d)
       (set-box! tree
                 (for/fold ([t tree0]) ([c (in-list cs)])
                   (define delta (if (eq? (cut-axis c) 'lr) (- col c0) (- row r0)))
                   (tree-resize-seam t c delta)))]
      [(select)
       (match-define (list _ p v anchor) d)
       (define-values (l c) (panel-screen-position->point p row col))
       (when l
         (view-set-selections! v (selections-one (selection anchor (point l c)))))])))

(define (release!) (set-box! drag #f))

(define (scroll! row col up?)
  (define p (panel-at (panels) row col))
  (when (and p (not (panel-empty? p)))
    (view-scroll! (panel-view p) (if up? -3 3))))

;;; ════════════ 绘制 ════════════

(define (draw!)
  (define p (panels))
  (panels-sync! p)
  (define w (unbox W)) (define h (unbox H))
  (define first? (not cache))
  ;; 增量：只发变化格（差量自己会把旧内容擦成空白）。首帧才清屏。
  (define-values (c r s) (render-display-patch p (unbox focus) w h cache))
  (set! cache c)
  (put-bytes (bytes-append (if first? (render-clear) (bytes))
                           (render-pieces (append r s))))
  (flush!))

(define (mouse->rc e) (values (max 0 (sub1 (mouse-event-y e))) (max 0 (sub1 (mouse-event-x e)))))

;;; ════════════ 主循环 ════════════

(define (run-tui!)
  (with-tui
   (λ ()
     (cursor-hide)
     (enable-mouse!)
     (draw!)
     (let loop ()
       (define e (read-event))
       (cond
         [(resize-event? e)
          (set-box! W (resize-event-cols e))
          (set-box! H (resize-event-rows e))
          (set! cache #f)
          (draw!) (loop)]
         [(null-event? e) (loop)]
         [(key-event? e)
          (define-values (st proc) (key-reader-feed! reader e))
          (when (eq? st 'command) (proc '()))
          (draw!)
          (when (unbox running?) (loop))]
         [(mouse-event? e)
          (define-values (row col) (mouse->rc e))
          (case (mouse-event-action e)
            [(press)   (press! row col)]
            [(move)    (move! row col)]
            [(release) (release!)]
            [(scroll)  (scroll! row col (eq? (mouse-event-button e) 'up))]
            [else (void)])
          (draw!)
          (loop)]
         [else (loop)])))))

;;; ════════════ headless 自检 ════════════

(define (rect-of id) (cadr (assoc id (tree->placements (unbox tree) (area)))))
(define (panel-of v) (for/first ([p (in-list (panels))] #:when (eq? (panel-view p) v)) p))
(define (check ok? label) (if ok? (printf "  ✓ ~a\n" label) (error 'check "~a 失败" label)))

(define (run-check!)
  (printf "初始：panels=~a  cuts=~a\n" (length (panels))
          (map (λ (c) (list (cut-axis c) (cut-offset c))) (tree->cuts (unbox tree) (area))))

  ;; 拖缝（竖）
  (define seam-x (rect-x (rect-of 'editor)))
  (define w0 (rect-w (rect-of 'tree)))
  (press! 5 seam-x) (move! 5 (+ seam-x 8)) (release!)
  (printf "拖右 8：tree w ~a → ~a\n" w0 (rect-w (rect-of 'tree)))
  (check (> (rect-w (rect-of 'tree)) w0) "拖缝：tree 变宽")

  ;; 角拖
  (define cuts (tree->cuts (unbox tree) (area)))
  (define ir (cut-offset (car (filter (λ (c) (eq? (cut-axis c) 'tb)) cuts))))
  (define ic (rect-x (rect-of 'editor)))
  (define e0 (rect-h (rect-of 'editor)))
  (press! ir ic) (move! (+ ir 3) (+ ic 5)) (release!)
  (printf "角拖：editor h ~a → ~a\n" e0 (rect-h (rect-of 'editor)))
  (check (> (rect-h (rect-of 'editor)) e0) "角拖：editor 变高")

  ;; 点击落光标（先重置布局 + 同步视口，保证 editor 够宽）
  (set-box! tree (base-tree)) (set! cache #f) (panels-sync! (panels))
  (define ep (panel-of ev))
  (define c (panel-content ep))
  (define sr (+ (rect-y c) 1)) (define sc (+ (rect-x c) 2))   ; 内容内 (1,2)
  (press! sr sc) (release!)
  (printf "点击 → 光标 = ~a  focus=~a\n" (view-point ev) (eq? (unbox focus) ev))
  (check (equal? (view-point ev) (point 1 2)) "点击落光标")
  (check (eq? (unbox focus) ev) "点击切焦点")

  ;; 拖选
  (press! sr sc) (move! (+ sr 1) (+ sc 3)) (release!)
  (define pr (view-primary-range ev))
  (printf "拖选 → 选区数=~a range=~a..~a\n"
          (view-selection-count ev) (range-start pr) (range-end pr))
  (check (= (view-selection-count ev) 1) "有选区")
  (check (not (range-empty? pr)) "选区非空")

  ;; 点到 tree 面板：焦点切到 tree
  (define tp (panel-of tv))
  (define tc (panel-content tp))
  (press! (+ (rect-y tc) 1) (+ (rect-x tc) 1)) (release!)
  (printf "点 tree → focus=tree? ~a  tree 光标=~a\n"
          (eq? (unbox focus) tv) (view-point tv))
  (check (eq? (unbox focus) tv) "焦点切到 tree")

  (displayln "interactive layout demo: 自检 OK"))

(module+ main
  (if (positive? (vector-length (current-command-line-arguments)))
      (run-check!)
      (run-tui!)))
