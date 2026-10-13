#lang racket

;;; edit4-test/command.rkt —— 命令层（binding / keymap / scope / dispatch / 基础命令）

(require rackunit
         racket/list
         "../edit4/layout.rkt"
         "../edit4/core.rkt")

(define SZ (cons 80 24))

(define (mk-ctx w ev)
  (define area (rect 0 0 (car SZ) (cdr SZ)))
  (define tiled (layout (world-layout w) area))
  (define frects (place-floats (geometry-rects tiled) (world-floats w) area))
  (ctx ev SZ (frame tiled frects (car SZ) (cdr SZ))))

(define (run w ev)
  (call-with-values (lambda () (dispatch base-commands base-scopes base-keymap (mk-ctx w ev) w)) list))

(define (w1 st) (car st))

;;; ---------- 单窗起步 ----------

(define w0 (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0))
(check-equal? (ids (world-layout w0)) '(0))
(check-true (focused? w0))

;;; ---------- prefix：C-s 进入 split 前缀 ----------

(define s1 (run w0 (key-event 's '(ctrl))))
(check-equal? (world-prefix (w1 s1)) 'split)

;;; 前缀态下按 →：split 'h after，新窗聚焦
(define s2 (run (w1 s1) (key-event 'right '())))
(define w2 (w1 s2))
(check-equal? (ids (world-layout w2)) '(0 1))
(check-equal? (world-focus w2) 1)
(check-equal? (world-prefix w2) #f)              ; 跑完自动清 prefix

;;; 几何：两列（分裂后 basis 各 2 → 等比 → 40/39）
(define g2 (layout (world-layout w2) (rect 0 0 80 24)))
(check-equal? (hash-ref (geometry-rects g2) 0) (rect 0 0 40 24))
(check-equal? (hash-ref (geometry-rects g2) 1) (rect 41 0 39 24))

;;; ---------- next / prev 环绕（edit3：M-n / M-p；方向焦点在 edit3 里没有绑定） ----------

(check-equal? (world-focus (w1 (run w2 (key-event 'n '(alt))))) 0)
(check-equal? (world-focus (w1 (run w2 (key-event 'p '(alt))))) 0)

;; 方向焦点仍是 focus 命令的能力，只是没有 M- 绑定（用自定义键表验证）。
(define km-left (list (list '(key f5) 'always (cmd 'focus 'left))))
(check-equal? (world-focus (w1 (call-with-values
                                (lambda () (dispatch base-commands base-scopes km-left
                                                     (mk-ctx w2 (key-event 'f5 '())) w2))
                                list)))
              0)

;;; ---------- 关闭：焦点回退，树收拢 ----------

(define c1 (run w2 (key-event 'd '(ctrl))))       ; focus=1 → 摘 1
(check-equal? (ids (world-layout (w1 c1))) '(0))
(check-equal? (world-focus (w1 c1)) 0)

;;; ---------- decline（#f）→ 继续下一条 entry ----------

(define (h-decline ctx w args) #f)
(define (h-mark ctx w args) (cons (world-set-focus w 'MARK) '()))
(define reg2 (command-register (command-register base-commands 'maybe h-decline) 'mark h-mark))
(define km2 (list (list '(key z ctrl) 'always (cmd 'maybe))
                  (list '(key z ctrl) 'always (cmd 'mark))))
(define m1 (call-with-values
            (lambda () (dispatch reg2 base-scopes km2 (mk-ctx w0 (key-event 'z '(ctrl))) w0)) list))
(check-equal? (world-focus (w1 m1)) 'MARK)         ; 第一条让位，第二条生效

;;; ---------- 自定义 scope ----------

(define sc (scope-register base-scopes 'focused?
                           (lambda (w) (focused? w))))
(define km3 (list (list '(key y ctrl) 'focused? (cmd 'mark))))
;; 有焦点 → 生效
(define y1 (call-with-values
            (lambda () (dispatch reg2 sc km3 (mk-ctx w0 (key-event 'y '(ctrl))) w0)) list))
(check-equal? (world-focus (w1 y1)) 'MARK)
;; 无焦点 → scope 不成立，未命中
(define w0n (make-world #:layout (world-layout w0)))
(define y2 (call-with-values
            (lambda () (dispatch reg2 sc km3 (mk-ctx w0n (key-event 'y '(ctrl))) w0n)) list))
(check-equal? (world-focus (w1 y2)) #f)

;;; ---------- keymap 组合：后者覆盖同 slot ----------

(define km-base (list (list '(key q ctrl) 'always (cmd 'focus 'next))))
(define km-over (list (list '(key q ctrl) 'always (cmd 'focus 'prev))))
(define composed (compose-keymaps (list km-base km-over)))
(check-equal? (length composed) 1)
(check-equal? (entry-commands (car composed)) (list (cmd 'focus 'prev)))

;;; ---------- prefix 未命中事件 → 清掉 ----------

(define w3 (make-world #:layout (world-layout w0) #:focus 0 #:prefix 'split))
(define miss (run w3 (key-event 'z '())))
(check-equal? (world-prefix (w1 miss)) #f)

;;; ---------- 拖拽：平铺缝（十字路口） ----------

(define (lf id) (leaf id (cons 2 2)))
(define l2x2 (split 'h 1 (list (child (size 2 #t) (split 'v 1 (list (child (size 2 #t) (lf 'a)) (child (size 2 #t) (lf 'b)))))
                               (child (size 2 #t) (split 'v 1 (list (child (size 2 #t) (lf 'c)) (child (size 2 #t) (lf 'd))))))))
(define wg (make-world #:layout l2x2 #:focus 'a))

(define press (run wg (cursor-event 'press 'left 40 12)))
(check-true (dragging? (world-drag (w1 press))))
(define moved (run (w1 press) (cursor-event 'move 'left 42 13)))
(define mg (layout (world-layout (w1 moved)) (rect 0 0 80 24)))
(check-equal? (hash-ref (geometry-rects mg) 'a) (rect 0 0 42 13))
(check-equal? (hash-ref (geometry-rects mg) 'd) (rect 43 14 37 10))
(define released (run (w1 moved) (cursor-event 'release 'left 42 13)))
(check-true (idle? (world-drag (w1 released))))

;; 不在拖拽时 pointer-move 让位（World 不变）
(define idle-move (run w0 (cursor-event 'move 'left 5 5)))
(check-true (idle? (world-drag (w1 idle-move))))

;;; ---------- 拖拽：浮窗移动 / 角缩放 ----------

(define wf (make-world #:layout l2x2
                       #:floats (list (float 'F (anchor 'screen 'left 'top 1 1) (cons 6 3)))
                       #:focus 'a))
;; 框内 (2,2) → move；同时聚焦浮窗
(define fp (run wf (cursor-event 'press 'left 2 2)))
(check-true (dragging? (world-drag (w1 fp))))
(check-equal? (world-focus (w1 fp)) 'F)
(define fm (run (w1 fp) (cursor-event 'move 'left 5 4)))
(check-equal? (float-anchor (float-by-id (world-floats (w1 fm)) 'F))
              (anchor 'screen 'left 'top 4 3))
;; 角 (1,1) → resize 'nw（对边不动）
(define fc (run wf (cursor-event 'press 'left 1 1)))
(define fm2 (run (w1 fc) (cursor-event 'move 'left 2 2)))
(define fF (float-by-id (world-floats (w1 fm2)) 'F))
(check-equal? (float-size fF) (cons 5 2))
(check-equal? (float-anchor fF) (anchor 'screen 'left 'top 2 2))

(displayln "edit4/command.rkt: all tests passed")
