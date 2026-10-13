#lang racket

;;; edit4-test/sidebar.rkt —— 侧栏宽度策略：启动按屏宽算、夹上下限，运行时 resize 不变

(require rackunit racket/list racket/file
         "../edit4/layout.rkt"
         "../edit4/core.rkt"
         "../edit4/core/world.rkt"
         "../edit4/content/model.rkt"
         "../edit4/content/commands.rkt"
         "../edit4/content/scopes.rkt"
         "../edit4/config/sidebar.rkt"
         "../edit4/boot.rkt")

;;; ---------- 纯函数：比例 + 上下限 ----------

(check-equal? (sidebar-width 1) sidebar-min-width)     ; 极窄 → 抬到 min
(check-true (<= sidebar-min-width (sidebar-width 80) sidebar-max-width))
(check-true (<= (sidebar-width 80) (sidebar-width 300)))   ; 单调不减
(check-equal? (sidebar-width 100000) sidebar-max-width)    ; 极宽 → 压到 max

;;; ---------- boot：按屏宽定侧栏；resize 不改 ----------

(define dir (make-temporary-file "ed4side~a" 'directory))
(define base (sidebar-width 160))
(define w (boot #:root dir #:screen-width 160))
(define rid (region-wid (hash-ref (content-regions (world-content w)) 'sidebar)))
(check-not-false rid)
(define (sidebar-w-at w cols)
  (define rects (geometry-rects (layout (world-layout w) (rect 0 0 cols 40))))
  (rect-w (hash-ref rects rid)))
(check-equal? (sidebar-w-at w 160) base)              ; 启动宽度 = sidebar-width(屏宽)
(check-equal? (sidebar-w-at w 240) base)              ; 运行时拉宽，侧栏不动
(check-equal? (sidebar-w-at w 100) base)              ; 运行时压窄，侧栏不动（未触下限）
(check-equal? (region-size (hash-ref (content-regions (world-content w)) 'sidebar)) base)

;; 屏宽更小 → 侧栏按比例缩小（但不低于 min）
(define wn (boot #:root dir #:screen-width 60))
(define rn (region-wid (hash-ref (content-regions (world-content wn)) 'sidebar)))
(define rects-n (geometry-rects (layout (world-layout wn) (rect 0 0 60 40))))
(check-equal? (rect-w (hash-ref rects-n rn)) (sidebar-width 60))

;;; ---------- C-b 隐藏/显示：按隐藏时的宽度恢复（用户拖过也一样） ----------

(define reg (command-registry-merge base-commands content-commands))
(define km (compose-keymaps (list content-keymap base-keymap)))
(define SZ (cons 160 40))
(define (mk-ctx w ev)
  (define area (rect 0 0 (car SZ) (cdr SZ)))
  (define tiled (layout (world-layout w) area))
  (define frects (place-floats (geometry-rects tiled) (world-floats w) area))
  (ctx ev SZ (frame tiled frects (car SZ) (cdr SZ))))
(define (run w ev)
  (car (call-with-values (lambda () (dispatch reg content-scopes km (mk-ctx w ev) w)) list)))
(define (region-of w rid) (hash-ref (content-regions (world-content w)) rid))
(define (sidebar-width-of w)
  (define r (region-of w 'sidebar))
  (define rects (geometry-rects (layout (world-layout w) (rect 0 0 (car SZ) (cdr SZ)))))
  (rect-w (hash-ref rects (region-wid r))))

(define wb (boot #:root dir #:screen-width 160))
(check-equal? (sidebar-width-of wb) base)
;; 拖缝把侧栏改宽（缝在 x = base）
(define d2 (run (run wb (cursor-event 'press 'left base 5))
                (cursor-event 'move 'left (+ base 12) 5)))
(define dragged (sidebar-width-of d2))
(check-not-equal? dragged base)                       ; 确实被拖宽
;; C-b 隐藏 → 再 C-b 显示：宽度 = 隐藏时的宽度
(define h1 (run d2 (key-event 'b '(ctrl))))
(check-false (region-wid (region-of h1 'sidebar)))
(define h2 (run h1 (key-event 'b '(ctrl))))
(check-not-false (region-wid (region-of h2 'sidebar)))
(check-equal? (sidebar-width-of h2) dragged)

;;; ---------- 区域声明驱动：tree 可放顶部 ----------

(define wt (boot #:root dir #:screen-width 160
                 #:regions '((tree top 8 ("*tree*") "*tree*" root shown)
                             (log  bottom 6 ("*log*") "*log*" main hidden))))
(define rects-t (geometry-rects (layout (world-layout wt) (rect 0 0 160 40))))
(define tree-wid (region-wid (hash-ref (content-regions (world-content wt)) 'tree)))
(check-not-false tree-wid)
(check-equal? (rect-y (hash-ref rects-t tree-wid)) 0)     ; 顶部
(check-equal? (rect-h (hash-ref rects-t tree-wid)) 8)     ; 高度 8
(check-equal? (rect-w (hash-ref rects-t tree-wid)) 160)   ; 跨满宽
(check-equal? (content-vid-of (world-content wt) tree-wid)
              (content-panel-vid (world-content wt) "*tree*"))

(displayln "edit4/sidebar.rkt: all tests passed")
