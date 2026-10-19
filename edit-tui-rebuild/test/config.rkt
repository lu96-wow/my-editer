#lang racket

;;; config 规则 / min-max / focus fallback 测试。
(require rackunit
         "../model/config.rkt"
         "../model/layout.rkt"
         "../model/panel.rkt"
         "../../core/view/base/rect.rkt")

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
  (define l0 (make-layout #:root (leaf 'editor)
                          #:panels (hash 'editor ed)
                          #:focus 'editor))
  (attach! (attach! l0 'editor 'left ft) 'editor 'down st))

;;; ---------- 默认规则 ----------
(check-true (config-panel-splittable? default-config 'editor))
(check-false (config-panel-splittable? default-config 'sidebar))
(check-false (config-panel-splittable? default-config 'status))
(check-true (config-panel-hideable? default-config 'sidebar))
(check-false (config-panel-hideable? default-config 'status))
(check-true (config-panel-deletable? default-config 'sidebar))
(check-false (config-panel-deletable? default-config 'status))

;; 未知 kind → default-rule
(check-false (config-panel-splittable? default-config 'unknown))
(check-true (config-panel-focusable? default-config 'unknown))

;;; ---------- 操作受规则限制 ----------
(define l (base-layout))

(define-values (_split-no ok-split-no?) (layout-split l 'filetree 'right 'nope))
(check-false ok-split-no?)

(define-values (_hide-no ok-hide-no?) (layout-panel-hide l area 'state))
(check-false ok-hide-no?)                                  ; status 不可隐

(define-values (_remove-no ok-remove-no?) (layout-panel-remove l 'state))
(check-false ok-remove-no?)                                ; status 不可删

;;; ---------- min / max 接缝夹取 ----------
(define editor-min20
  (make-panel-rule #:splittable? #t
                   #:hideable? #f
                   #:deletable? #t
                   #:focusable? #t
                   #:min-w 20 #:max-w #f
                   #:min-h 1 #:max-h #f))
(define config-min20
  (make-layout-config
   #:rules (hash 'editor editor-min20
                 'sidebar (config-panel-rule default-config 'sidebar)
                 'status (config-panel-rule default-config 'status))))

(define-values (l-flex ok-flex?) (layout-panel-set-fixed l 'filetree 'w #f))
(check-true ok-flex?)
(define root-seam (layout-seam-at l-flex area 0 40))
(check-not-false root-seam)
(define-values (l-ratio _) (layout-split-set-ratio l-flex (seam-split-id root-seam) 3/8))
(define rects0 (layout-panel-rects l-ratio area))
(check-equal? (hash-ref rects0 'filetree) (rect 0 0 30 24))

;; 右子树 min-w = max(editor 20, state 1) = 20 → 左最多 60
(define-values (l-clamped ok-clamped?)
  (layout-seam-resize l-ratio area (seam-split-id root-seam) 100 #:config config-min20))
(check-true ok-clamped?)
(define rects1 (layout-panel-rects l-clamped area))
(check-equal? (hash-ref rects1 'filetree) (rect 0 0 60 24))
(check-equal? (hash-ref rects1 'editor) (rect 60 0 20 23))

(define editor-max40
  (make-panel-rule #:splittable? #t
                   #:hideable? #f
                   #:deletable? #t
                   #:focusable? #t
                   #:min-w 1 #:max-w 40
                   #:min-h 1 #:max-h #f))
(define config-max40
  (make-layout-config
   #:rules (hash 'editor editor-max40
                 'sidebar (config-panel-rule default-config 'sidebar)
                 'status (config-panel-rule default-config 'status))))

;; 右子树 max-w = min(editor 40, state #f) = 40 → 左最少 40
(define-values (l-clamped2 ok-clamped2?)
  (layout-seam-resize l-ratio area (seam-split-id root-seam) -100 #:config config-max40))
(check-true ok-clamped2?)
(define rects2 (layout-panel-rects l-clamped2 area))
(check-equal? (hash-ref rects2 'filetree) (rect 0 0 40 24))
(check-equal? (hash-ref rects2 'editor) (rect 40 0 40 23))

;;; ---------- validate ----------
(define editor-min60
  (make-panel-rule #:splittable? #t
                   #:hideable? #f
                   #:deletable? #t
                   #:focusable? #t
                   #:min-w 60 #:max-w #f
                   #:min-h 1 #:max-h #f))
(define config-min60
  (make-layout-config
   #:rules (hash 'editor editor-min60
                 'sidebar (config-panel-rule default-config 'sidebar)
                 'status (config-panel-rule default-config 'status))))

(check-true (layout-valid? l area default-config))
(define violations (layout-validate l area config-min60))
(check-true (for/or ([v (in-list violations)])
              (and (equal? (car v) 'editor) (eq? (cadr v) 'w))))
(check-false (layout-valid? l area config-min60))

;;; ---------- focus fallback：跳过不可聚焦 ----------
(define editor-no-focus
  (make-panel-rule #:splittable? #t
                   #:hideable? #f
                   #:deletable? #t
                   #:focusable? #f
                   #:min-w 1 #:max-w #f
                   #:min-h 1 #:max-h #f))
(define config-no-editor-focus
  (make-layout-config
   #:rules (hash 'editor editor-no-focus
                 'sidebar (config-panel-rule default-config 'sidebar)
                 'status (config-panel-rule default-config 'status))))

(define l-focus-ft (layout-set-focus l 'filetree))
(define-values (l-hidden ok-hidden?)
  (layout-panel-hide l-focus-ft area 'filetree #:config config-no-editor-focus))
(check-true ok-hidden?)
;; 兄弟右子树里 editor 不可聚焦 → 落到 state
(check-equal? (layout-focus l-hidden) 'state)

(displayln "edit-tui-rebuild/test/config.rkt: ok")
