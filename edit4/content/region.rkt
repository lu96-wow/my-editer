#lang racket

;;; edit4/content/region.rkt —— 面板槽（region）：一个窗口显示多个面板之一
;;;
;;; region = 边/尺寸/成员/当前成员/锚点/窗口；成员互斥显示。
;;;   show   ：隐藏则新建窗格插入（anchor root 包整树；main 贴主编辑器窗），再绑定成员 vid；
;;;   hide   ：摘掉窗格；
;;;   cycle/activate/focus：换成员 / 聚焦（隐藏则先显示）。
;;;
;;; 布局手术用 layout 的 insert-side / insert-adjacent / remove-leaf。

(provide region-commands region-ref region-show region-hide)

(require racket/list
         "../core/world.rkt" "../core/command.rkt"
         "../layout.rkt"
         "model.rkt" "adapter.rkt" "lifecycle.rkt")

(define (region-ref w rid) (hash-ref (content-regions (world-content w)) rid #f))

(define (region-set w rid r)
  (define c (world-content w))
  (world-set-content w (content-set-regions c (hash-set (content-regions c) rid r))))

(define (region-set-active w rid name)
  (define r (region-ref w rid))
  (if r (region-set w rid (struct-copy region r [active name])) w))

;; 当前窗口的 vid 换成 active 成员的 vid（已显示时）。
(define (region-sync w rid)
  (define c (world-content w))
  (define r (region-ref w rid))
  (cond
    [(not (and c r (region-wid r))) w]
    [else (define vid (content-panel-vid c (region-active r)))
          (if vid (world-set-content w (content-bind c (region-wid r) vid)) w)]))

;; 显示（隐藏则新建窗格插入）。
(define (region-show w rid)
  (define c (world-content w))
  (define r (region-ref w rid))
  (cond
    [(not (and c r)) w]
    [(region-wid r) (region-sync w rid)]
    [else
     (define lay (world-layout w))
     (define nid (fresh-id lay))
     (define sz (size (region-size r) #f))
     (define nleaf (leaf nid (cons 1 1)))
     (define nlay
       (case (region-anchor r)
         [(main) (define target (content-editor-window c lay))
                 (if target (insert-adjacent lay target (region-side r) sz nleaf)
                     (insert-side lay (region-side r) sz nleaf))]
         [else (insert-side lay (region-side r) sz nleaf)]))
     (define r* (struct-copy region r [wid nid]))
     (region-sync (region-set (world-set-layout w nlay) rid r*) rid)]))

;; 隐藏（摘掉窗格）。
(define (region-hide w rid)
  (define c (world-content w))
  (define r (region-ref w rid))
  (cond
    [(not (and c r (region-wid r))) w]
    [else
     (define lay (remove-leaf (world-layout w) (region-wid r)))
     (define r* (struct-copy region r [wid #f]))
     (ensure-focus (region-set (world-set-layout w lay) rid r*))]))

;;; ---------- 命令 ----------

(define (h-region-cycle ctx w args)
  (define rid (car args))
  (define r (region-ref w rid))
  (cond
    [(not r) #f]
    [else
     (define ms (region-members r))
     (define cur (region-active r))
     (define i (or (for/first ([m (in-list ms)] [i (in-naturals)] #:when (equal? m cur)) i) 0))
     (define next (list-ref ms (modulo (add1 i) (length ms))))
     (cons (region-show (region-set-active w rid next) rid) '())]))

(define (h-region-activate ctx w args)
  (define rid (car args))
  (define name (cadr args))
  (cond [(not (region-ref w rid)) #f]
        [else (cons (region-show (region-set-active w rid name) rid) '())]))

(define (h-region-toggle ctx w args)
  (define rid (car args))
  (define r (region-ref w rid))
  (cond
    [(not r) #f]
    [else (cons (if (region-wid r) (region-hide w rid) (region-show w rid)) '())]))

(define (h-region-focus ctx w args)
  (define rid (car args))
  (define w* (region-show w rid))
  (define r (region-ref w* rid))
  (cond [(not (and r (region-wid r))) #f]
        [else (cons (world-set-focus w* (region-wid r)) '())]))

(define region-commands
  (make-command-registry
   (list (cons 'region-cycle h-region-cycle)
         (cons 'region-activate h-region-activate)
         (cons 'region-toggle h-region-toggle)
         (cons 'region-focus h-region-focus))))
