#lang racket

;;; edit4-test/log-region.rkt —— 日志面板 + 区域显示/隐藏

(require rackunit
         racket/list racket/file racket/path
         "../edit4/layout.rkt"
         "../edit4/core.rkt"
         "../edit4/content/model.rkt"
         "../edit4/content/adapter.rkt"
         "../edit4/content/commands.rkt"
         "../edit4/content/scopes.rkt"
         "../edit4/view/log.rkt"
         "../edit4/boot.rkt")

(define dir (simplify-path (make-temporary-file "ed4log~a" 'directory)))
(define reg (command-registry-merge base-commands content-commands))
(define km (compose-keymaps (list content-keymap base-keymap)))
(define SZ (cons 80 24))
(define (mk-ctx w ev)
  (define area (rect 0 0 (car SZ) (cdr SZ)))
  (define tiled (layout (world-layout w) area))
  (define frects (place-floats (geometry-rects tiled) (world-floats w) area))
  (ctx ev SZ (frame tiled frects (car SZ) (cdr SZ))))
(define (run w ev)
  (call-with-values (lambda () (dispatch reg content-scopes km (mk-ctx w ev) w)) list))
(define (W st) (car st))
(define (region-of w rid) (hash-ref (content-regions (world-content w)) rid))

;;; ---------- 默认：侧栏显示，日志隐藏 ----------

(define w0 (boot #:root dir))
(check-equal? (length (ids (world-layout w0))) 4)           ; 2 主区 + sidebar + log（叶子都常驻）
(check-equal? (length (visible-ids (world-layout w0))) 3)   ; log 折叠 → 不可见
(check-false (region-wid (region-of w0 'log)))
(check-not-false (region-wid (region-of w0 'sidebar)))

;;; ---------- C-l 显示 / 隐藏日志（结构不变，仅展开/折叠） ----------

(define l1 (run w0 (key-event 'l '(ctrl))))
(check-not-false (region-wid (region-of (W l1) 'log)))
(check-equal? (length (ids (world-layout (W l1)))) 4)           ; 叶子常驻
(check-equal? (length (visible-ids (world-layout (W l1)))) 4)   ; log 展开 → 可见
(define lgw (region-wid (region-of (W l1) 'log)))
(check-equal? (content-vid-of (world-content (W l1)) lgw)
              (content-panel-vid (world-content (W l1)) "*log*"))
(define l2 (run (W l1) (key-event 'l '(ctrl))))
(check-false (region-wid (region-of (W l2) 'log)))
(check-equal? (length (ids (world-layout (W l2)))) 4)
(check-equal? (length (visible-ids (world-layout (W l2)))) 3)

;;; ---------- C-b 隐藏 / 显示侧栏 ----------

(define b1 (run w0 (key-event 'b '(ctrl))))
(check-false (region-wid (region-of (W b1) 'sidebar)))
(check-equal? (length (ids (world-layout (W b1)))) 4)           ; 叶子仍在，只是折叠
(check-equal? (length (visible-ids (world-layout (W b1)))) 2)   ; 只剩编辑器 + 状态栏
(define b2 (run (W b1) (key-event 'b '(ctrl))))
(check-not-false (region-wid (region-of (W b2) 'sidebar)))
(check-equal? (content-vid-of (world-content (W b2)) (region-wid (region-of (W b2) 'sidebar)))
              (content-panel-vid (world-content (W b2)) "*tree*"))

;; 可折叠 dock：叶子常驻，隐藏只改 size；叶子 id / 窗口 id 跨显隐稳定
(define sleaf (region-leaf (region-of w0 'sidebar)))
(define swid0 (region-wid (region-of w0 'sidebar)))
(check-equal? (region-leaf (region-of (W b1) 'sidebar)) sleaf)   ; 隐藏后叶子 id 不变
(check-equal? (region-wid (region-of (W b2) 'sidebar)) swid0)    ; 再显示还是同一个窗 id

;;; ---------- (region ID) 作用域：按声明自动生成 ----------

(define rsw (region-wid (region-of w0 'sidebar)))
(check-true (scope-ok? content-scopes (world-set-focus w0 rsw) '(region sidebar)))
(check-false (scope-ok? content-scopes w0 '(region sidebar)))   ; 焦点在编辑器

;;; ---------- 日志投影 ----------

(define c1 (content-log-append (content-log-append (world-content w0) "hello") "world"))
(define w1 (world-set-content w0 c1))
(define lvid (content-panel-vid c1 "*log*"))
(define-values (text faces) (log-content w1 lvid))
(check-equal? text "hello\nworld")
(check-equal? faces (list (cons 0 'log) (cons 1 'log)))

(displayln "edit4/log-region.rkt: all tests passed")
