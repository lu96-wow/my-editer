#lang racket

;;; layout 状态 / split tree / hide / show / remove / split 测试。
(require rackunit
         "../config/layout/default.rkt"
         "../main.rkt")

(define area (rect 0 0 80 24))

(define (attach! l target dir p)
  (define-values (l* ok?) (layout-panel-attach l target dir p))
  (check-true ok?)
  l*)

(define (split! l target dir id)
  (define-values (l* ok?) (layout-split l target dir id #:config default-config))
  (check-true ok?)
  l*)

(define (hide! l area id)
  (define-values (l* ok?) (layout-panel-hide l area id #:config default-config))
  (check-true ok?)
  l*)

(define (show! l area id)
  (define-values (l* ok?) (layout-panel-show l area id))
  (check-true ok?)
  l*)

(define (clear! l id)
  (define-values (l* ok?) (layout-panel-clear-content l id))
  (check-true ok?)
  l*)

(define (remove! l id)
  (define-values (l* ok?) (layout-panel-remove l id #:config default-config))
  (check-true ok?)
  l*)

;;; ---------- 初始布局 ----------
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
(define l1 (attach! l0 'editor 'left ft))
(define l2 (attach! l1 'editor 'down st))

(check-true (split? (layout-root l2)))
(check-equal? (layout-visible-panel-ids l2) '(filetree editor state))
(check-equal? (layout-focus l2) 'editor)                  ; attach 不抢焦点

(define pass2 (layout-solve l2 area))
(define rects2 (layout-solution-panel-rects pass2))
(check-equal? (hash-ref rects2 'filetree) (rect 0 0 30 24))
(check-equal? (hash-ref rects2 'editor) (rect 30 0 50 23))
(check-equal? (hash-ref rects2 'state) (rect 30 23 50 1))

;; 接缝：根是 lr，内层是 tb
(define root-seam (layout-seam-at l2 area 0 30))
(check-not-false root-seam)
(check-equal? (seam-axis root-seam) 'lr)
(define inner-seam (layout-seam-at l2 area 23 40))
(check-not-false inner-seam)
(check-equal? (seam-axis inner-seam) 'tb)

;;; ---------- 固定尺寸阻止拖接缝 ----------
(define-values (_l1 no-resize?) (layout-seam-resize l2 area (seam-split-id root-seam) 5 #:config default-config))
(check-false no-resize?)                                  ; filetree fixed-w = 30
(define-values (_l2 no-resize-inner?) (layout-seam-resize l2 area (seam-split-id inner-seam) 2 #:config default-config))
(check-false no-resize-inner?)                            ; state fixed-h = 1
(check-false (layout-seam-drag-start l2 area 0 30 #:config default-config))            ; filetree fixed-w
(check-false (layout-seam-drag-start l2 area 23 40 #:config default-config))           ; state fixed-h

;;; ---------- flex 接缝拖动 ----------
(define-values (l-flex ok-flex?) (layout-panel-set-fixed l2 'filetree 'w #f))
(check-true ok-flex?)
(define seam-flex (layout-seam-at l-flex area 0 40))
(check-not-false seam-flex)
(define-values (l-ratio _) (layout-split-set-ratio l-flex (seam-split-id seam-flex) 3/8))
(define rects-ratio (layout-panel-rects l-ratio area))
(check-equal? (hash-ref rects-ratio 'filetree) (rect 0 0 30 24))

(define d (layout-seam-drag-start l-ratio area 0 30 #:config default-config))
(check-not-false d)
(define-values (l-dragged ok-drag?) (layout-seam-drag-move l-ratio area d 0 35 #:config default-config))
(check-true ok-drag?)
(define rects-dragged (layout-panel-rects l-dragged area))
(check-equal? (hash-ref rects-dragged 'filetree) (rect 0 0 35 24))

(define-values (l-resized ok-resize?) (layout-seam-resize l-ratio area (seam-split-id seam-flex) 5 #:config default-config))
(check-true ok-resize?)
(define rects-resized (layout-panel-rects l-resized area))
(check-equal? (hash-ref rects-resized 'filetree) (rect 0 0 35 24))
(check-equal? (hash-ref rects-resized 'editor) (rect 35 0 45 23))
(check-equal? (hash-ref rects-resized 'state) (rect 35 23 45 1))

;;; ---------- 隐藏：兄弟吸收 ----------
(define l-focus (layout-set-focus l-resized 'filetree))
(define l-hidden (hide! l-focus area 'filetree))
(check-false (layout-panel-visible? l-hidden 'filetree))
(check-equal? (layout-focus l-hidden) 'editor)            ; 焦点回退
(define rects-hidden (layout-panel-rects l-hidden area))
(check-false (hash-ref rects-hidden 'filetree #f))
(check-equal? (hash-ref rects-hidden 'editor) (rect 0 0 80 23))
(check-equal? (hash-ref rects-hidden 'state) (rect 0 23 80 1))

;;; ---------- 显示：按比例放回，窗口变大 ----------
(define area2 (rect 0 0 160 30))
(define l-shown (show! l-hidden area2 'filetree))
(define rects-shown (layout-panel-rects l-shown area2))
;; 隐藏时 ratio = 35 / 80 = 7/16；新宽度 = 160 * 7/16 = 70
(check-equal? (hash-ref rects-shown 'filetree) (rect 0 0 70 30))
(check-equal? (hash-ref rects-shown 'editor) (rect 70 0 90 29))
(check-equal? (hash-ref rects-shown 'state) (rect 70 29 90 1))

;;; ---------- split：只有 editor 能拆，新 panel 空且不抢焦点 ----------
(define-values (l-split ok-split?) (layout-split l-shown 'editor 'right 'editor2 #:config default-config))
(check-true ok-split?)
(check-equal? (layout-focus l-split) 'editor)
(define ed2 (layout-panel l-split 'editor2))
(check-not-false ed2)
(check-equal? (panel-kind ed2) 'editor)
(check-false (panel-view ed2))
(check-true (layout-panel-visible? l-split 'editor2))
(check-equal? (layout-visible-panel-ids l-split) '(filetree editor editor2 state))

(define-values (_l-no-split no-split?) (layout-split l-split 'filetree 'right 'nope #:config default-config))
(check-false no-split?)

;;; ---------- clear：保留 slot，清内容 ----------
(define l-cleared (clear! l-split 'editor))
(check-true (layout-panel-visible? l-cleared 'editor))
(check-false (panel-view (layout-panel l-cleared 'editor)))
(check-not-false (layout-panel l-cleared 'editor))

;;; ---------- remove：父 split 塌缩到兄弟 ----------
(define l-removed (remove! l-cleared 'filetree))
(check-false (layout-panel l-removed 'filetree))
(check-equal? (layout-visible-panel-ids l-removed) '(editor editor2 state))

;; 删掉根 panel → 空布局
(define l-single (make-layout #:root (make-leaf 'only)
                            #:panels (hash 'only (make-empty-editor-panel 'only))
                            #:focus 'only))
(define l-none (remove! l-single 'only))
(check-true (layout-empty? l-none))
(check-false (layout-focus l-none))

(displayln "edit-tui-rebuild/test/layout.rkt: ok")
