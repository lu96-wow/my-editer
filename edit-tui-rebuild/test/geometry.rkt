#lang racket

;;; geometry 测试：layout-solve → core panel 列表。
(require rackunit
         "../api/layout.rkt"
         "../api/panel.rkt"
         "../api/geometry.rkt"
         "../api/base.rkt"
         (prefix-in core- "../../core/view/panel.rkt"))

(define area (rect 0 0 80 24))

(define (attach! l target dir p)
  (define-values (l* ok?) (layout-panel-attach l target dir p))
  (check-true ok?)
  l*)

(define (hide! l area id)
  (define-values (l* ok?) (layout-panel-hide l area id))
  (check-true ok?)
  l*)

(define (panel-by-view ps v)
  (for/first ([p (in-list ps)] #:when (equal? (core-panel-view p) v)) p))

;;; ---------- 初始布局 ----------
(define ft (make-panel 'filetree 'sidebar
                       #:views '(ft-view)
                       #:active 'ft-view
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
(define l1 (attach! l0 'editor 'left ft))
(define l2 (attach! l1 'editor 'down st))

;;; ---------- 渲染投影：view = active ----------
(define ps (layout->render-panels l2 area))
(check-equal? (map core-panel-view ps) '(ft-view #f status-view))
(check-equal? (map core-panel-rect ps)
              (list (rect 0 0 30 24)
                    (rect 30 0 50 23)
                    (rect 30 23 50 1)))

;; filetree 有右边框：内容区宽 29
(define ftp (panel-by-view ps 'ft-view))
(check-equal? (let ([c (core-panel-content ftp)])
                (list (rect-w c) (rect-h c)))
              '(29 24))

;;; ---------- 命中投影：view = panel-id ----------
(define hps (layout->hit-panels l2 area))
(check-equal? (map core-panel-view hps) '(filetree editor state))
(check-equal? (map core-panel-rect hps)
              (list (rect 0 0 30 24)
                    (rect 30 0 50 23)
                    (rect 30 23 50 1)))

;;; ---------- rects ----------
(define rs (layout-panel-rects l2 area))
(check-equal? (hash-ref rs 'filetree) (rect 0 0 30 24))
(check-equal? (hash-ref rs 'editor) (rect 30 0 50 23))
(check-equal? (hash-ref rs 'state) (rect 30 23 50 1))

;;; ---------- 隐藏：filetree 不产出 panel，editor/state 扩宽 ----------
(define l-hidden (hide! l2 area 'filetree))
(define ps-hidden (layout->render-panels l-hidden area))
(check-equal? (map core-panel-view ps-hidden) '(#f status-view))
(check-equal? (map core-panel-rect ps-hidden)
              (list (rect 0 0 80 23)
                    (rect 0 23 80 1)))

(displayln "edit-tui-rebuild/test/geometry.rkt: ok")
