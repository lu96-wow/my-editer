#lang racket

;;; placement 交互：临时表（方向键改焦点）压栈 / 解除。
(require rackunit
         "../config/keymap/default.rkt"
         "../main.rkt")

(define area (rect 0 0 60 20))

(define filetree-panel
  (make-panel 'filetree 'sidebar #:views '(10) #:active 10 #:borders '(right)))
(define editor1-panel
  (make-panel 'editor1 'editor #:borders '(up down left right)))
(define editor2-panel
  (make-panel 'editor2 'editor #:borders '(up down left right)))

;; filetree | (editor1 / editor2)
(define l0
  (make-layout #:root (make-leaf 'editor1)
               #:panels (hash 'editor1 editor1-panel)
               #:focus 'editor1))
(define-values (l1 ok1?)
  (layout-panel-attach l0 'editor1 'left filetree-panel #:ratio 1/4))
(define-values (l2 ok2?)
  (layout-panel-attach l1 'editor1 'down editor2-panel))
(unless (and ok1? ok2?) (error 'placement-test "layout"))

(define state
  (make-app-state #:layout (layout-set-focus l2 'filetree)
                  #:keymap default-keymap
                  #:area area))

(define (focus state) (layout-focus (app-state-layout state)))
(define (overlay-tables state)
  (command-table-stack-tables (app-state-overlays state)))
(define (press state tok)
  (step state (key-event tok)))

;;; ---------- 开始 placement：自动聚焦 editor + 压临时表 ----------
(define s1 (start-placement state 99))
(check-equal? (focus s1) 'editor1)
(check-not-false (memq placement-table (overlay-tables s1)))
(check-equal? (length (overlay-tables s1))
              (add1 (length (overlay-tables state))))

;;; ---------- 方向键改焦点（跳过非 editor） ----------
(define-values (s2 a2) (press s1 (key 'down)))
(check-equal? a2 '())
(check-equal? (focus s2) 'editor2)

;; 左边是 filetree（sidebar），不是合法目标 -> 焦点不动
(define-values (s2b a2b) (press s2 (key 'left)))
(check-equal? a2b '())
(check-equal? (focus s2b) 'editor2)
(check-true (string-contains? (app-state-flash s2b) "no editor"))

;;; ---------- Enter 放入 + 解除临时表 ----------
(define-values (s3 a3) (press s2b (key 'enter)))
(check-equal? a3 '())
(check-false (app-state-placement s3))
(check-not-false (memv 99 (layout-panel-view-ids (app-state-layout s3) 'editor2)))
(check-false (memq placement-table (overlay-tables s3)))
(check-equal? (app-state-flash s3) "view placed")

;;; ---------- 解除后方向键不再改焦点（普通键位恢复） ----------
(define-values (s3b a3b) (press s3 (key 'down)))
(check-equal? a3b '())
(check-equal? (focus s3b) 'editor2)

;;; ---------- Esc 取消也会解除临时表 ----------
(define s4 (start-placement state 100))
(check-not-false (memq placement-table (overlay-tables s4)))
(define-values (s5 a5) (press s4 (key 'escape)))
(check-equal? a5 '())
(check-false (app-state-placement s5))
(check-false (memq placement-table (overlay-tables s5)))

;;; ---------- 焦点本来就在 editor：不抢焦点 ----------
(define s6 (start-placement (struct-copy app-state state
                                         [layout (layout-set-focus l2 'editor2)])
                            101))
(check-equal? (focus s6) 'editor2)

(displayln "edit-tui-rebuild/test/placement.rkt: ok")
