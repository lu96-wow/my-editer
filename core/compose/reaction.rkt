#lang racket

(require "../text/point.rkt" "../text/content.rkt" "../text/buffer.rkt"
         "../view/window.rkt" "../view/view.rkt" "../view/rebase.rkt"
         "editor.rkt" rackunit)

;;; core/compose/reaction.rkt —— 显示语义：内容变更后，视图怎么反应
;;;
;;; 内容面（editor-apply-desc）只管「换 buffer 引用」，光标一个都不碰。
;;; 本层是唯一的**显示语义**层，全部是 editor -> editor 的纯函数，三选一：
;;;
;;;   editor-clamp-views   none   字面不动，只把光标/视口夹回合法域（可能文本变小）
;;;   editor-map-views     map    每个同 buffer view 各自把光标映射过这次编辑（不滚屏）
;;;   editor-leader-view   leader 指定 view 推进到插入后 + ensure；同 buffer 其余
;;;                               free 映射光标 / follow 复制 leader 最终视口
;;;
;;; 另有 editor-leader-window：用户导航用——把一个 view 的 window 定稿，同 buffer 的
;;; follow 镜像它（不含内容变更）。
;;;
;;; 契约：显示语义**只在同一 buffer 的 view 之间**发生；跨 buffer 无耦合。
;;; leader 必须**先 ensure 定稿**，follower 再复制（否则差一行）。

(provide editor-clamp-views
         editor-map-views
         editor-leader-view
         editor-leader-window)

;; none：只夹紧（换 buffer 引用时已保留旧光标；文本可能变小 → 必须夹回合法域）。
(define (editor-clamp-views ed bid)
  (for/fold ([e ed]) ([v (in-list (editor-views ed))])
    (if (= bid (view-buffer-id v))
        (let ([w (view-window v)])
          (editor-put-view e (view-id v) (window-clamp-view (window-set-point w (window-point w)))))
        e)))

;; map：每个同 buffer view 各自 free 映射光标；不设 leader、不滚屏、不复制视口。
(define (editor-map-views ed bid b* d)
  (for/fold ([e ed]) ([v (in-list (editor-views ed))])
    (if (= bid (view-buffer-id v))
        (editor-put-view e (view-id v) (rebase-free (view-window v) b* d))
        e)))

;; leader：vid 推进到插入后 + ensure；同 buffer 其余 free 映射 / follow 镜像。
(define (editor-leader-view ed vid b* d)
  (define v (editor-view-ref ed vid))
  (define bid (view-buffer-id v))
  (define editing
    (window-ensure-point
     (struct-copy window (view-window v) [buffer b*] [point (edit-desc-after-position d)])))
  (for/fold ([e ed]) ([x (in-list (editor-views ed))])
    (cond
      [(not (= bid (view-buffer-id x))) e]
      [(= vid (view-id x)) (editor-put-view e vid editing)]
      [else
       (define w (case (view-sync x)
                   [(free)   (rebase-free   (view-window x) b* d)]
                   [(follow) (rebase-follow (view-window x) editing)]))
       (editor-put-view e (view-id x) w)])))

;; 用户导航：把 vid 的 window 定稿；同 buffer 的 follow view 镜像它（自由 view 钉住）。
(define (editor-leader-window ed vid w*)
  (define v (editor-view-ref ed vid))
  (define bid (view-buffer-id v))
  (for/fold ([e ed]) ([x (in-list (editor-views ed))])
    (cond
      [(= vid (view-id x)) (editor-put-view e vid w*)]
      [(and (= bid (view-buffer-id x)) (eq? (view-sync x) 'follow))
       (editor-put-view e (view-id x) (rebase-follow (view-window x) w*))]
      [else e])))

;;; ---------- 测试 ----------

(module+ test
  (define b* (buffer-open "XYl0\nl1\nl2\nl3"))
  (define d-ins (edit-desc (point 0 0) (point 0 0) "XY"))

  ;; none：光标字面不动（只夹紧，不映射）
  (define n0 (editor-open "l0\nl1\nl2\nl3"))
  (define-values (n0b nv) (editor-add-view n0 0 3 10 (point 0 1) #:focus? #f))
  (define n1 (let-values ([(e _) (editor-apply-desc n0b 0 d-ins)]) (editor-clamp-views e 0)))
  (check-equal? (editor-view-point n1 nv) (point 0 1))     ; 不随编辑移动

  ;; map：光标随编辑右移，视口不动
  (define m0 (editor-open "l0\nl1\nl2\nl3"))
  (define-values (m0b mv) (editor-add-view m0 0 3 10 (point 0 1) #:focus? #f))
  (define m1 (let-values ([(e d*) (editor-apply-desc m0b 0 d-ins)])
               (editor-map-views e 0 (editor-buffer e 0) d*)))
  (check-equal? (editor-view-point m1 mv) (point 0 3))     ; (0,1) 映射到 (0,3)
  (check-equal? (editor-view-top-line m1 mv) 0)

  ;; leader：leader 推进，follow 镜像
  (define g0 (editor-open "l0\nl1\nl2\nl3\nl4\nl5" 3 10))
  (define-values (g1 gv) (editor-add-view g0 0 3 10 #:sync 'follow #:focus? #f))
  (define g2 (editor-focus-view g1 0))
  (define-values (g3 dg) (editor-apply-desc g2 0 (edit-desc (point 0 0) (point 0 0) "XY")))
  (define g4 (editor-leader-view g3 0 (editor-buffer g3 0) dg))
  (check-equal? (editor-point g4) (point 0 2))
  (check-equal? (editor-view-point g4 gv) (point 0 2))
  (check-eq? (editor-buffer g4 0) (window-buffer (view-window (editor-view-ref g4 gv))))

  (displayln "reaction.rkt: all tests passed"))
