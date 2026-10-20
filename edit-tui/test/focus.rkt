#lang racket

;;; 焦点导航测试：方向 / 鼠标 / focusable 过滤 / hidden。
(require rackunit
         "../main.rkt"
         (prefix-in c: "../../core/view/panel.rkt"))

(define area (rect 0 0 80 24))

(define (attach! l target dir p)
  (define-values (l* ok?) (layout-panel-attach l target dir p))
  (check-true ok?)
  l*)

(define (base-layout)
  (define ft (make-panel 'filetree 'sidebar
                         #:fixed-w 30
                         #:borders '(right)))
  (define st (make-panel 'state 'status
                         #:views '(status-view)
                         #:active 'status-view
                         #:fixed-h 1))
  (define ed (make-empty-editor-panel 'editor))
  (define l0 (make-layout #:root (make-leaf 'editor)
                          #:panels (hash 'editor ed)
                          #:focus 'editor))
  (attach! (attach! l0 'editor 'left ft) 'editor 'down st))

(define l (base-layout))

;;; ---------- 可聚焦判断 ----------
(check-true (layout-panel-focusable? l default-config 'filetree))
(check-true (layout-panel-focusable? l default-config 'editor))
(check-true (layout-panel-focusable? l default-config 'state))
(check-false (layout-panel-focusable? l default-config 'nope))

;;; ---------- 方向导航 ----------
(check-equal? (layout-focus-neighbor l area default-config 'editor 'left) 'filetree)
(check-equal? (layout-focus-neighbor l area default-config 'editor 'down) 'state)
(check-false (layout-focus-neighbor l area default-config 'editor 'up))
(check-false (layout-focus-neighbor l area default-config 'editor 'right))

(check-equal? (layout-focus-neighbor l area default-config 'filetree 'right) 'editor)
(check-false (layout-focus-neighbor l area default-config 'filetree 'down))

(check-equal? (layout-focus-neighbor l area default-config 'state 'left) 'filetree)
(check-equal? (layout-focus-neighbor l area default-config 'state 'up) 'editor)
(check-false (layout-focus-neighbor l area default-config 'state 'right))

;;; ---------- focusable? = #f 会被跳过 ----------
(define editor-no-focus
  (make-panel-rule #:splittable? #t
                   #:hideable? #f
                   #:deletable? #t
                   #:focusable? #f
                   #:min-w 1 #:max-w #f
                   #:min-h 1 #:max-h #f))
(define config-no-editor
  (make-layout-config
   #:rules (hash 'editor editor-no-focus
                 'sidebar (config-panel-rule default-config 'sidebar)
                 'status (config-panel-rule default-config 'status))))

(check-false (layout-panel-focusable? l config-no-editor 'editor))
;; editor 不可聚焦：filetree 右边只剩 state
(check-equal? (layout-focus-neighbor l area config-no-editor 'filetree 'right) 'state)
(check-false (layout-focus-neighbor l area config-no-editor 'editor 'left))

;;; ---------- 鼠标命中 ----------
(check-equal? (layout-focus-panel-at l area default-config 0 0) 'filetree)
(check-equal? (layout-focus-panel-at l area default-config 0 30) 'editor)
(check-equal? (layout-focus-panel-at l area default-config 23 30) 'state)
(check-false (layout-focus-panel-at l area config-no-editor 0 30))
(check-false (layout-focus-panel-at l area default-config 100 100))

;;; ---------- hidden panel 不参与 ----------
(define-values (l-hidden ok-hidden?) (layout-panel-hide l area 'filetree))
(check-true ok-hidden?)
(check-false (layout-panel-focusable? l-hidden default-config 'filetree))
(check-false (layout-focus-neighbor l-hidden area default-config 'editor 'left))
;; 隐藏 filetree 后 editor 扩到 (0,0,80,23)
(check-equal? (layout-focus-panel-at l-hidden area default-config 0 0) 'editor)

;;; ---------- panels 投影 ----------
(define fps (layout-focusable-panels l area default-config))
(check-equal? (map (λ (p) (c:panel-view p)) fps) '(filetree editor state))

(displayln "edit-tui-rebuild/test/focus.rkt: ok")
