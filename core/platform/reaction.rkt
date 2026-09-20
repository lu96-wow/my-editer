#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt"
         "../doc/buffer.rkt"
         "../viewport/window.rkt" "../viewport/layout.rkt" "../viewport/rebase.rkt"
         "../unit/history.rkt"
         "state.rkt" "write.rkt" rackunit)

;;; platform/reaction.rkt —— 显示语义：内容变更后，视图怎么反应
;;;
;;; 内容面（editor-apply-edit）只管「换 buffer 引用」，光标一个都不碰。
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
;;;
;;; 本层只依赖 platform 的数据/写原语（state.rkt / write.rkt）；不认识中性接口/程序面/用户面。

(provide editor-clamp-views
         editor-map-views
         editor-leader-view
         editor-leader-window)

;; none：只夹紧（换 buffer 引用时已保留旧光标；文本可能变小 → 必须夹回合法域）。
(define (editor-clamp-views ed b)
  (for/fold ([e ed]) ([v (in-list (editor-views ed))])
    (if (eq? b (view-buffer v))
        (let ([w (view-window v)])
          (editor-put-view e (view-id v)
                           (window-clamp-view (window-clamp-selections w))))
        e)))

;; map：每个同 buffer view 各自 free 映射所有选区（按施加顺序折叠过整批 descs）；
;; 不设 leader、不滚屏、不复制视口。
(define (editor-map-views ed b descs)
  (for/fold ([e ed]) ([v (in-list (editor-views ed))])
    (if (eq? b (view-buffer v))
        (editor-put-view e (view-id v) (rebase-free (view-window v) b descs))
        e)))

;; leader：vid 的选区推进到插入后 + ensure；同 buffer 其余 free 映射 / follow 镜像。
(define (editor-leader-view ed vid b descs)
  (define v (editor-view-ref ed vid))
  (define editing (rebase-leader (view-window v) b descs))
  (for/fold ([e ed]) ([x (in-list (editor-views ed))])
    (cond
      [(not (eq? b (view-buffer x))) e]
      [(= vid (view-id x)) (editor-put-view e vid editing)]
      [else
       (define w (case (view-sync x)
                   [(free)   (rebase-free   (view-window x) b descs)]
                   [(follow) (rebase-follow (view-window x) editing)]))
       (editor-put-view e (view-id x) w)])))

;; 用户导航：把 vid 的 window 定稿；同 buffer 的 follow view 镜像它（自由 view 钉住）。
(define (editor-leader-window ed vid w*)
  (define b (view-buffer (editor-view-ref ed vid)))
  (for/fold ([e ed]) ([x (in-list (editor-views ed))])
    (cond
      [(= vid (view-id x)) (editor-put-view e vid w*)]
      [(and (eq? b (view-buffer x)) (eq? (view-sync x) 'follow))
       (editor-put-view e (view-id x) (rebase-follow (view-window x) w*))]
      [else e])))

;;; ---------- 测试（只经机制层造 editor） ----------

(module+ test
  ;; 造一个单 buffer 单 view 的 editor；再加一个 view（可指定 sync）
  (define (mk text h w)
    (define b (buffer-open text))
    (editor (list (buffer-entry 0 "s" b (history-empty)))
            (list (view 0 (window-open b h w) 'free)) 0 1 1))
  (define (add-view ed h w p sync)
    (define b (buffer-entry-buffer (editor-buffer-entry ed 0)))
    (struct-copy editor ed
      [views (append (editor-views ed)
                     (list (view (editor-next-view ed)
                                 (window-set-point (window-open b h w) p) sync)))]
      [next-view (add1 (editor-next-view ed))]))
  (define (vp ed vid) (window-point (view-window (editor-view-ref ed vid))))
  (define (vtl ed vid) (window-top-line (view-window (editor-view-ref ed vid))))
  (define (vb ed bid) (buffer-entry-buffer (editor-buffer-entry ed bid)))

  (define d-ins (edit-desc (point 0 0) (point 0 0) "XY"))

  ;; none：光标字面不动（只夹紧，不映射）
  (define n0 (add-view (mk "l0\nl1\nl2\nl3" 3 10) 3 10 (point 0 1) 'free))
  (define n1 (let-values ([(e _) (editor-apply-edit n0 0 d-ins)]) (editor-clamp-views e (vb e 0))))
  (check-equal? (vp n1 1) (point 0 1))                     ; 不随编辑移动

  ;; map：光标随编辑右移，视口不动
  (define m0 (add-view (mk "l0\nl1\nl2\nl3" 3 10) 3 10 (point 0 1) 'free))
  (define m1 (let-values ([(e d*) (editor-apply-edit m0 0 d-ins)])
               (editor-map-views e (vb e 0) (list d*))))
  (check-equal? (vp m1 1) (point 0 3))                     ; (0,1) 映射到 (0,3)
  (check-equal? (vtl m1 1) 0)

  ;; leader：leader 推进，follow 镜像
  (define g0 (add-view (mk "l0\nl1\nl2\nl3\nl4\nl5" 3 10) 3 10 (point 0 0) 'follow))
  (define-values (g3 dg) (editor-apply-edit g0 0 (edit-desc (point 0 0) (point 0 0) "XY")))
  (define g4 (editor-leader-view g3 0 (vb g3 0) (list dg)))
  (check-equal? (vp g4 0) (point 0 2))
  (check-equal? (vp g4 1) (point 0 2))
  (check-eq? (vb g4 0) (window-buffer (view-window (editor-view-ref g4 1))))

  (displayln "reaction.rkt: all tests passed"))
