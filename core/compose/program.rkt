#lang racket

(require "../text/point.rkt" "../text/content.rkt" "../text/buffer.rkt" "../text/edit.rkt"
         "../view/window.rkt"
         "editor.rkt" "reaction.rkt" rackunit)

;;; core/compose/program.rkt —— 程序面：内容变更 + 显式视图命令
;;;
;;; 程序操作的语义：
;;;   · 内容变更默认 **none**：只换 buffer 值，光标/视口字面不动（只夹紧合法性）。
;;;     需要光标跟随文本时显式给 #:reaction 'map。可在编辑点留下可撤销的一步。
;;;   · 视图命令都是「只动指定的那个 view」，绝不镜像、不抢焦点、不 ensure。
;;;
;;; 用户面（焦点/leader/ensure/账本）在 command.rkt。

(provide
 editor-edit-at
 editor-set-point
 editor-view-set-point
 editor-set-view-size
 editor-set-mode)

;; 在 bid 的显式位置 p 编辑。op : buffer point → (or/c #f edit-desc)。
;; 返回 (values editor (or/c #f change-report))。
;; #:reaction  'none（默认）| 'map   内容变更后视图怎么反应
;; #:trusted?  #t 跳过 read-only 守卫（格式化器）
;; #:record?   #t 记一步账本（pre-point = 夹紧后的编辑点）
(define (editor-edit-at ed bid p op
                        #:reaction [reaction 'none]
                        #:trusted? [trusted? #f]
                        #:record? [record? #f])
  (define b0 (editor-buffer ed bid))
  (define d (op b0 p))
  (cond
    [(not d) (values ed #f)]
    [else
     (define-values (ed* d*) (editor-apply-desc ed bid d (not trusted?)))
     (cond
       [(not d*) (values ed #f)]
       [else
        (define b* (editor-buffer ed* bid))
        (define ed** (case reaction
                       [(none) (editor-clamp-views ed* bid)]
                       [(map)  (editor-map-views ed* bid b* d*)]
                       [else (error 'editor-edit-at "reaction 必须是 'none 或 'map，得到 ~a" reaction)]))
        (define ed*** (if record?
                          (editor-record-history
                           ed** bid
                           (edit-change d* (buffer-edit-desc-inverse b0 d*) (edit-desc-start d*)))
                          ed**))
        (define-values (f l) (edits-span (list d*)))
        (values ed*** (change-report f l))])]))

;;; ---------- 显式视图命令（只动一个 view，不镜像） ----------

(define (editor-set-point ed p)
  (editor-put-view ed (editor-focus ed)
                   (window-set-point (view-window (editor-focused-view ed)) p)))

(define (editor-view-set-point ed vid p)
  (editor-put-view ed vid
                   (window-set-point (view-window (editor-view-ref ed vid)) p)))

(define (editor-set-view-size ed vid height width)
  (editor-put-view ed vid
                   (window-set-size (view-window (editor-view-ref ed vid)) height width)))

(define (editor-set-mode ed mode)
  (editor-put-view ed (editor-focus ed)
                   (window-set-mode (view-window (editor-focused-view ed)) mode)))

;;; ---------- 测试 ----------

(module+ test
  ;; 默认 none：内容变了，光标字面不动
  (define e0 (editor-open "hello"))
  (define-values (e1 r1) (editor-edit-at e0 0 (point 0 0) (edit-splice (point 0 0) (point 0 0) "XY")))
  (check-equal? (editor-buffer->string e1 0) "XYhello")
  (check-equal? (editor-point e1) (point 0 0))          ; none
  (check-equal? (change-report-first-line r1) 0)
  (check-false (editor-can-undo? e1 0))                 ; 默认不记账本

  ;; 'map：光标跟随文本（光标在编辑点之后才会右移）
  (define e0s (editor-set-point e0 (point 0 3)))
  (define-values (e2 _r2) (editor-edit-at e0s 0 (point 0 1) (edit-insert "XY") #:reaction 'map))
  (check-equal? (editor-buffer->string e2 0) "hXYello")
  (check-equal? (editor-point e2) (point 0 5))          ; (0,3) 映射到 (0,5)
  ;; 同一场景改成 none：光标字面不动
  (define-values (e2n _r2n) (editor-edit-at e0s 0 (point 0 1) (edit-insert "XY")))
  (check-equal? (editor-point e2n) (point 0 3))

  ;; #:record? #t：记一步，pre-point = 编辑点
  (define-values (e3 _r3) (editor-edit-at e0 0 (point 0 2) (edit-insert "Z") #:record? #t))
  (check-true (editor-can-undo? e3 0))

  ;; #:trusted? #t 跳过 read-only 守卫
  (define tr (editor-put-restrict (editor-open "abc") 0 (point 0 0) (point 0 3) (restrict #t)))
  (define-values (tr1 rtr1) (editor-edit-at tr 0 (point 0 1) (edit-insert-char #\X)))
  (check-false rtr1)                                    ; 守卫版被拒
  (check-equal? (editor-buffer->string tr1 0) "abc")
  (define-values (tr2 _rtr2) (editor-edit-at tr 0 (point 0 1) (edit-insert-char #\X) #:trusted? #t))
  (check-equal? (editor-buffer->string tr2 0) "aXbc")

  ;; 显式视图命令不动别的 view
  (define v0 (editor-open "l0\nl1\nl2"))
  (define-values (v1 vv) (editor-add-view v0 0 3 10 #:focus? #f))
  (define v2 (editor-view-set-point v1 vv (point 2 0)))
  (check-equal? (editor-view-point v2 vv) (point 2 0))
  (check-equal? (editor-point v2) (point 0 0))          ; 焦点 view 不动

  (displayln "program.rkt: all tests passed"))
