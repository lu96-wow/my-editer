#lang racket

;;; lab-re-rebuild/kernel/workspace.rkt —— 工作区：主区(frame) + 停靠区(docks)。
;;;
;;; 布局纯派生：按 side 依次从可用区域取条带，剩余给主区。
;;; 焦点几何：主区叶 rect + dock rect 统一参与方向导航。
;;;
;;; 「实现共用」就在这层；具体 dock 逻辑在 builtin/status.rkt / builtin/tree.rkt。

(require "editor-api.rkt" "frame.rkt" "dock.rkt")

(provide (struct-out workspace) workspace-new
         workspace-dock workspace-dock-vid
         workspace-dock-visible workspace-dock-size
         workspace-areas workspace->rectangles)

(struct workspace (main docks) #:transparent)
;; main  : frame
;; docks : (listof dock)

(define (workspace-new main docks) (workspace main docks))

(define (workspace-dock ws id)
  (for/first ([d (in-list (workspace-docks ws))] #:when (eq? id (dock-id d))) d))

(define (workspace-dock-vid ws id)
  (define d (workspace-dock ws id))
  (and d (dock-vid d)))

(define (workspace-map-docks ws f)
  (workspace (workspace-main ws)
             (for/list ([d (in-list (workspace-docks ws))]) (f d))))

(define (workspace-dock-visible ws id flag)
  (workspace-map-docks ws (λ (d) (if (eq? id (dock-id d)) (struct-copy dock d [visible? flag]) d))))

(define (workspace-dock-size ws id n)
  (workspace-map-docks ws (λ (d) (if (eq? id (dock-id d)) (struct-copy dock d [size (max 1 n)]) d))))

;; side 处理顺序：top → bottom → left → right。
;; top/bottom 先切（横跨全宽），left/right 再切（占据上/下条之间的剩余高度）。
(define (side-order s)
  (case s [(top) 0] [(bottom) 1] [(left) 2] [(right) 3] [else 4]))

;; → (values main-area (listof (cons dock area)))。
(define (workspace-areas ws w h)
  (define visible
    (sort (for/list ([d (in-list (workspace-docks ws))] #:when (dock-visible? d)) d)
          < #:key (λ (d) (side-order (dock-side d)))))
  (define-values (rest out)
    (for/fold ([a (area 0 0 w h)] [out '()]) ([d (in-list visible)])
      (define side (dock-side d))
      (define horiz? (memq side '(left right)))
      (define avail (if horiz? (area-w a) (area-h a)))
      (define s (max 1 (min (dock-size d) (max 1 (sub1 avail)))))
      (define-values (strip rest*)
        (case side
          [(left)  (values (area (area-x a) (area-y a) s (area-h a))
                           (area (+ (area-x a) s) (area-y a) (- (area-w a) s) (area-h a)))]
          [(right) (values (area (- (+ (area-x a) (area-w a)) s) (area-y a) s (area-h a))
                           (area (area-x a) (area-y a) (- (area-w a) s) (area-h a)))]
          [(top)   (values (area (area-x a) (area-y a) (area-w a) s)
                           (area (area-x a) (+ (area-y a) s) (area-w a) (- (area-h a) s)))]
          [(bottom)(values (area (area-x a) (- (+ (area-y a) (area-h a)) s) (area-w a) s)
                           (area (area-x a) (area-y a) (area-w a) (- (area-h a) s)))]))
      (values rest* (cons (cons d strip) out))))
  (values rest (reverse out)))

;; 工作区所有窗格的 rectangle：主区叶 + 各 dock（焦点几何 / 渲染共用）。
(define (workspace->rectangles ws w h)
  (define-values (main dock-pairs) (workspace-areas ws w h))
  (append
   (frame->rectangles (workspace-main ws) main)
   (for/list ([dp (in-list dock-pairs)])
     (define d (car dp))
     (define a (cdr dp))
     (rectangle (dock-vid d) (area-x a) (area-y a) (area-w a) (area-h a) 0))))
