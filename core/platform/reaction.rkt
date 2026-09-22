#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt"
         "../doc/buffer.rkt" "../doc/document.rkt"
         "../viewport/window.rkt" "../viewport/layout.rkt" "../viewport/rebase.rkt" "../viewport/mirror.rkt"
         "../unit/history.rkt"
         "state.rkt" "write.rkt" rackunit)

;;; platform/reaction.rkt —— 显示语义：内容变更后，视图怎么反应
;;;
;;; 内容面（editor-apply-change）只管「换 document 引用」，光标一个都不碰。
;;; 本层是唯一的**显示语义**层，全部是 editor -> editor 的纯函数，三选一：
;;;
;;;   editor-clamp-views   none   字面不动，只把光标/视口夹回合法域（可能文本变小）
;;;   editor-map-views     map    每个同 document view 各自把光标映射过这次编辑（不滚屏）
;;;   editor-leader-view   leader 指定 view 推进到插入后 + ensure；同 link 成员按视口镜像
;;;                               （可跨 document），同 document 其余 free 映射 / follow 复制最终视口
;;;
;;; 另有 editor-leader-window：用户导航用——把一个 view 的 window 定稿，同 link 成员按视口镜像，
;;; 同 document 的 follow 镜像它（不含内容变更）。
;;;
;;; 契约：`free` / `follow` 显示语义**只在同一 document 的 view 之间**发生；跨 document 只走
;;; `link` 的视口镜像（不改对方的 document / 选区）。leader 必须**先 ensure 定稿**，follower 再复制
;;; （否则差一行）。
;;;
;;; 本层只依赖 platform 的数据/写原语（state.rkt / write.rkt）；不认识中性接口/程序面/用户面。

(provide editor-clamp-views
         editor-map-views
         editor-leader-view
         editor-leader-window
         editor-align-link)

;; none：只夹紧（换 document 引用时已保留旧光标；文本可能变小 → 必须夹回合法域）。
(define (editor-clamp-views ed d)
  (for/fold ([e ed]) ([v (in-list (editor-views ed))])
    (if (eq? d (view-document v))
        (let ([w (view-window v)])
          (editor-put-view e (view-id v)
                           (window-clamp-view (window-clamp-selections w))))
        e)))

;; map：每个同 document view 各自 free 映射所有选区（按施加顺序折叠过整批 descs）；
;; 不设 leader、不滚屏、不复制视口。
(define (editor-map-views ed d descs)
  (for/fold ([e ed]) ([v (in-list (editor-views ed))])
    (if (eq? d (view-document v))
        (editor-put-view e (view-id v) (rebase-free (view-window v) d descs))
        e)))

;; leader：vid 的选区推进到插入后 + ensure；同 link 成员按视口镜像（可跨 document），
;; 同 document 其余 free 映射 / follow 镜像。
(define (editor-leader-view ed vid d descs)
  (define v (editor-view-ref ed vid))
  (define link (view-link v))
  (define editing (rebase-leader (view-window v) d descs))
  ;; 同 document 的 view 先把光标映射过这次编辑；跨 document 的保持原样。
  (define (base-window x)
    (cond
      [(not (eq? d (view-document x))) (view-window x)]
      [(eq? (view-sync x) 'follow) (rebase-follow (view-window x) editing)]
      [else (rebase-free (view-window x) d descs)]))
  (for/fold ([e ed]) ([x (in-list (editor-views ed))])
    (cond
      [(= vid (view-id x)) (editor-put-view e vid editing)]
      ;; 同 link（可跨 document）：只镜像视口，不改成员自己的 document
      [(and link (eq? link (view-link x)))
       (editor-put-view e (view-id x) (mirror-window editing (base-window x)))]
      [(not (eq? d (view-document x))) e]
      [else (editor-put-view e (view-id x) (base-window x))])))

;; 用户导航：把 vid 的 window 定稿；同 link 成员按视口镜像，同 document 的 follow view 镜像它。
(define (editor-leader-window ed vid w*)
  (define v (editor-view-ref ed vid))
  (define d (view-document v))
  (define link (view-link v))
  (for/fold ([e ed]) ([x (in-list (editor-views ed))])
    (cond
      [(= vid (view-id x)) (editor-put-view e vid w*)]
      [(and link (eq? link (view-link x)))
       ;; 同 document 的成员带上 leader 的选区；跨 document 的只镜像视口。
       (define w0 (view-window x))
       (define base (if (and (eq? d (view-document x)) (eq? (view-sync x) 'follow))
                        (rebase-follow w0 w*)
                        w0))
       (editor-put-view e (view-id x) (mirror-window w* base))]
      [(and (eq? d (view-document x)) (eq? (view-sync x) 'follow))
       (editor-put-view e (view-id x) (rebase-follow (view-window x) w*))]
      [else e])))

;; 把一个 link 组对齐到**参考成员**：`from`（若在组内）→ 焦点 view（若在组内）→ 组内第一个成员。
;; 参考成员自身不动，其余成员按 mirror-window 投参考窗口视口。空组 / #f → 恒等。
(define (editor-align-link ed link [from #f])
  (define members (if link
                      (filter (lambda (v) (eq? link (view-link v))) (editor-views ed))
                      '()))
  (define (member? vid) (and vid (for/or ([v (in-list members)]) (= vid (view-id v)))))
  (define focus (editor-focus ed))
  (define src-id (cond [(member? from) from]
                       [(member? focus) focus]
                       [(pair? members) (view-id (car members))]
                       [else #f]))
  (cond
    [(not src-id) ed]
    [else
     (define w (view-window (editor-view-ref ed src-id)))
     (for/fold ([e ed]) ([x (in-list members)])
       (if (= src-id (view-id x))
           e
           (editor-put-view e (view-id x) (mirror-window w (view-window x)))))]))

;;; ---------- 测试（只经机制层造 editor） ----------

(module+ test
  ;; 造一个单 document 单 view 的 editor；再加一个 view（可指定 sync）
  (define (mk text h w)
    (define d (document-open text))
    (editor (list (document-entry 0 "s" d (history-empty) #t))
            (list (view 0 (window-open d h w) 'free #f)) 0 1 1))
  (define (add-view ed h w p sync)
    (define d (document-entry-document (editor-document-entry ed 0)))
    (struct-copy editor ed
      [views (append (editor-views ed)
                     (list (view (editor-next-view ed)
                                 (window-set-point (window-open d h w) p) sync #f)))]
      [next-view (add1 (editor-next-view ed))]))
  (define (vp ed vid) (window-point (view-window (editor-view-ref ed vid))))
  (define (vtl ed vid) (window-top-line (view-window (editor-view-ref ed vid))))
  (define (vd ed did) (document-entry-document (editor-document-entry ed did)))

  (define d-ins (edit-desc (point 0 0) (point 0 0) "XY"))

  ;; none：光标字面不动（只夹紧，不映射）
  (define n0 (add-view (mk "l0\nl1\nl2\nl3" 3 10) 3 10 (point 0 1) 'free))
  (define n1 (let-values ([(e _) (editor-apply-edit n0 0 d-ins #f)]) (editor-clamp-views e (vd e 0))))
  (check-equal? (vp n1 1) (point 0 1))                     ; 不随编辑移动

  ;; map：光标随编辑右移，视口不动
  (define m0 (add-view (mk "l0\nl1\nl2\nl3" 3 10) 3 10 (point 0 1) 'free))
  (define m1 (let-values ([(e d*) (editor-apply-edit m0 0 d-ins #f)])
               (editor-map-views e (vd e 0) (list d*))))
  (check-equal? (vp m1 1) (point 0 3))                     ; (0,1) 映射到 (0,3)
  (check-equal? (vtl m1 1) 0)

  ;; leader：leader 推进，follow 镜像
  (define g0 (add-view (mk "l0\nl1\nl2\nl3\nl4\nl5" 3 10) 3 10 (point 0 0) 'follow))
  (define-values (g3 dg) (editor-apply-edit g0 0 (edit-desc (point 0 0) (point 0 0) "XY") #f))
  (define g4 (editor-leader-view g3 0 (vd g3 0) (list dg)))
  (check-equal? (vp g4 0) (point 0 2))
  (check-equal? (vp g4 1) (point 0 2))
  (check-eq? (vd g4 0) (window-document (view-window (editor-view-ref g4 1))))

  (displayln "reaction.rkt: all tests passed"))
