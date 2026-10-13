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

(check-equal? (sidebar-width 40) sidebar-min-width)   ; 10 → 抬到 min
(check-equal? (sidebar-width 80) 20)                  ; 20
(check-equal? (sidebar-width 120) 30)                 ; 30
(check-equal? (sidebar-width 200) sidebar-max-width)  ; 50 → 压到 max
(check-true (<= sidebar-min-width (sidebar-width 123) sidebar-max-width))

;;; ---------- boot：按屏宽定侧栏；resize 不改 ----------

(define dir (make-temporary-file "ed4side~a" 'directory))
(define w (boot #:root dir #:screen-width 160))
(define rid (region-wid (hash-ref (content-regions (world-content w)) 'sidebar)))
(check-not-false rid)
(define (sidebar-w-at w cols)
  (define rects (geometry-rects (layout (world-layout w) (rect 0 0 cols 40))))
  (rect-w (hash-ref rects rid)))
(check-equal? (sidebar-w-at w 160) 40)                ; sidebar-width(160) = 40
(check-equal? (sidebar-w-at w 240) 40)                ; 运行时拉宽，侧栏不动
(check-equal? (sidebar-w-at w 100) 40)                ; 运行时压窄，侧栏不动（未触下限）
(check-equal? (region-size (hash-ref (content-regions (world-content w)) 'sidebar)) 40)

;; 屏宽更小 → 侧栏按比例缩小（但不低于 min）
(define wn (boot #:root dir #:screen-width 60))
(define rn (region-wid (hash-ref (content-regions (world-content wn)) 'sidebar)))
(define rects-n (geometry-rects (layout (world-layout wn) (rect 0 0 60 40))))
(check-equal? (rect-w (hash-ref rects-n rn)) sidebar-min-width)

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
(check-equal? (sidebar-width-of wb) 40)
;; 拖缝把侧栏改宽（缝在 x = 40）
(define d2 (run (run wb (cursor-event 'press 'left 40 5)) (cursor-event 'move 'left 52 5)))
(define dragged (sidebar-width-of d2))
(check-not-equal? dragged 40)                         ; 确实被拖宽
;; C-b 隐藏 → 再 C-b 显示：宽度 = 隐藏时的宽度
(define h1 (run d2 (key-event 'b '(ctrl))))
(check-false (region-wid (region-of h1 'sidebar)))
(define h2 (run h1 (key-event 'b '(ctrl))))
(check-not-false (region-wid (region-of h2 'sidebar)))
(check-equal? (sidebar-width-of h2) dragged)

(displayln "edit4/sidebar.rkt: all tests passed")
