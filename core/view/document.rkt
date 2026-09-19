#lang racket

(require "../text/point.rkt" "../text/content.rkt" "../text/buffer.rkt"
         "../text/patch.rkt" "window.rkt" "view.rkt" rackunit)

;;; document.rkt —— 共享 buffer 的多视图容器
;;;
;;; 背景：buffer 是不可变快照；window 持有「buffer 引用 + 自己的光标」。多个 window
;;; 共享同一 buffer 时，各自编辑会出三类问题：
;;;   P1 分叉     A 编辑后 B 仍引用旧 buffer
;;;   P2 光标失效 A 在 B 光标之前增删，B 的 point 不再指向原文本
;;;   P3 丢失更新 B 基于旧 buffer 编辑，覆盖 A 的结果
;;;
;;; document 是单一事实源：一个 buffer + 一组视图（window + 同步模式），
;;; **所有编辑都经 document-edit 串行化**，编辑后每个视图按自己的模式重新基准。
;;; 不变量：任一 document 内，所有视图的 buffer 都 eq? 同一个。
;;;
;;; 视图同步模式（两档）：
;;;   'free   光标随文本映射（落在被删区间 → 吸附起点），视口不动（但仍在合法域内）
;;;   'follow 光标 + 视口锚点复制自编辑视图，再按自己的几何 window-ensure-point
;;; 正在被编辑的那个视图总是：光标推进到插入之后 + ensure-point。
;;;
;;; document-edit 的 op 形状与 buffer 层一致：op : buffer point → (or/c #f edit-desc)。

(provide
 (struct-out view)
 (struct-out document)
 document-open
 document-of-buffer
 document-view-count
 document-view-ref
 document-add-view
 document-window
 document-view-sync
 document-set-view-sync
 document-update-view
 document-sync-followers
 document-update-buffer
 document-put-property
 document-remove-property
 document-put-properties-many
 document-put-restrict
 document-apply-patches
 document-edit
 document-apply-descs-trusted
 document->string
 document->lines
 document-line-count
 document-line-ref
 document-get-property
 document-read-only-at?
 document-restrict-runs
 document-buffer)

;;; ---------- 数据 ----------

(struct view (window sync) #:transparent)
;; sync : 'free | 'follow

(struct document (buffer views) #:transparent)
;; buffer : buffer         当前共享 buffer（唯一事实源）
;; views  : (listof view)  顺序稳定，靠下标索引

;;; ---------- 构造 / 读 ----------

(define (document-open s) (document (buffer-open s) '()))
(define (document-of-buffer b) (document b '()))
(define (document-view-count doc) (length (document-views doc)))

(define (document->string doc) (buffer->string (document-buffer doc)))
(define (document->lines doc) (buffer->lines (document-buffer doc)))
(define (document-line-count doc) (buffer-line-count (document-buffer doc)))
(define (document-line-ref doc i) (buffer-line-ref (document-buffer doc) i))
(define (document-get-property doc line col key)
  (buffer-get-property (document-buffer doc) line col key))
(define (document-read-only-at? doc line col)
  (buffer-read-only-at? (document-buffer doc) line col))
(define (document-restrict-runs doc line)
  (buffer-restrict-runs (document-buffer doc) line))

(define (check-view-index who doc i)
  (unless (and (exact-nonnegative-integer? i) (< i (document-view-count doc)))
    (error who "视图下标越界: ~a（该 document 有 ~a 个视图）" i (document-view-count doc))))

(define (document-view-ref doc i)
  (check-view-index 'document-view-ref doc i)
  (list-ref (document-views doc) i))

(define (document-window doc i) (view-window (document-view-ref doc i)))
(define (document-view-sync doc i) (view-sync (document-view-ref doc i)))

;;; ---------- 视图管理 ----------

(define (check-sync who s)
  (unless (memq s '(free follow))
    (error who "sync 必须是 'free 或 'follow，得到 ~a" s)))

;; 注册一个视图，返回 (values document index)。消费方只给尺寸与初始光标。
(define (document-add-view doc [height 24] [width 80] [p (point 0 0)]
                           #:sync [sync 'free])
  (check-sync 'document-add-view sync)
  (define w (window-clamp-view (window-set-point (window-open (document-buffer doc) height width) p)))
  (values (struct-copy document doc
            [views (append (document-views doc) (list (view w sync)))])
          (document-view-count doc)))    ; 新下标 = 旧数量

(define (document-set-view-sync doc i sync)
  (check-sync 'document-set-view-sync sync)
  (check-view-index 'document-set-view-sync doc i)
  (struct-copy document doc
    [views (for/list ([j (in-naturals)] [v (in-list (document-views doc))])
             (if (= j i) (struct-copy view v [sync sync]) v))]))

;; 更新第 i 个视图的 window（导航/滚动/尺寸），夹回合法域后把 follow 视图对齐到它。
(define (document-update-view doc i f)
  (check-view-index 'document-update-view doc i)
  (document-sync-followers
   (struct-copy document doc
     [views (for/list ([j (in-naturals)] [v (in-list (document-views doc))])
              (if (= j i)
                  (struct-copy view v [window (window-clamp-view (f (view-window v)))])
                  v))])
   i))

;; 把 follow 视图对齐到第 i 视图（编辑路径内部已调；导航后单独用）。
(define (document-sync-followers doc i)
  (define lead (document-window doc i))
  (struct-copy document doc
    [views (for/list ([j (in-naturals)] [v (in-list (document-views doc))])
             (if (and (not (= j i)) (eq? (view-sync v) 'follow))
                 (view (rebase-follow (view-window v) lead) 'follow)
                 v))]))

;;; ---------- rebase 策略 ----------

(define (rebase-free w b* d)
  (define p (window-point w))
  (define p* (or (edit-desc-map-position d p) (edit-desc-start d)))
  (window-set-point (window-set-buffer w b*) p*))

(define (rebase-follow w editing)
  (window-ensure-point
   (struct-copy window w
     [buffer   (window-buffer editing)]
     [point    (window-point editing)]
     [top-line (window-top-line editing)]
     [left-col (window-left-col editing)]
     [top-seg  (window-top-seg editing)])))

;;; ---------- 装饰写回（活文档也能标注）----------
;;; 文本只能经 document-edit 改；属性/marker/overlay/patch 是 buffer 级装饰操作。
;;; document-update-buffer 把改过装饰的 buffer 装回，并同步每个视图的 buffer 引用
;;;（文本没变，光标不动）。

(define (document-update-buffer doc f)
  (define b* (f (document-buffer doc)))
  (struct-copy document doc
    [buffer b*]
    [views (for/list ([v (in-list (document-views doc))])
             (struct-copy view v [window (window-set-buffer (view-window v) b*)]))]))

(define (document-put-property doc line start end key val)
  (document-update-buffer doc (lambda (b) (buffer-put-property b line start end key val))))
(define (document-remove-property doc line start end key)
  (document-update-buffer doc (lambda (b) (buffer-remove-property b line start end key))))
(define (document-put-properties-many doc segs)
  (document-update-buffer doc (lambda (b) (buffer-put-properties-many b segs))))
(define (document-put-restrict doc line start end rs)
  (document-update-buffer doc (lambda (b) (buffer-put-restrict b line start end rs))))
(define (document-apply-patches doc patches)
  (document-update-buffer doc (lambda (b) (buffer-apply-patches b patches))))

;;; ---------- 编辑漏斗 ----------

;; 施加一条 desc 并 rebase。guard? = #f 时跳过守卫。返回 (values document 生效desc/#f)。
(define (apply-one doc i d guard?)
  (define b0 (document-buffer doc))
  (define-values (b* d*)
    (if guard? (buffer-apply-edit b0 d) (buffer-apply-edit-trusted b0 d)))
  (cond
    [(not d*) (values doc #f)]
    [else
     (define w (document-window doc i))
     ;; 编辑视图：光标推进到插入之后 + ensure-point。
     ;; 先把编辑视图的最终视口定下来，follow 才有正确的锚点可复制。
     (define editing
       (window-ensure-point
        (struct-copy window w [buffer b*] [point (edit-desc-after-position d*)])))
     (define views*
       (for/list ([j (in-naturals)] [v (in-list (document-views doc))])
         (define sync (view-sync v))
         (define w*
           (window-clamp-view
            (if (= j i) editing
                (case sync
                  [(free) (rebase-free (view-window v) b* d*)]
                  [(follow) (rebase-follow (view-window v) editing)]))))
         (view w* sync)))
     (values (document b* views*) d*)]))

;; 唯一的编辑入口。op : buffer point → (or/c #f edit-desc)。
;; 返回 (values document (or/c #f edit-change))；#f = 什么都没发生（no-op / 被守卫拒）。
;; 逆用**编辑前**的 buffer 导出；不记任何历史（入不入账由消费层决定）。
(define (document-edit doc i op)
  (check-view-index 'document-edit doc i)
  (define b0 (document-buffer doc))
  (define p0 (window-point (document-window doc i)))
  (define d (op b0 p0))
  (cond
    [(not d) (values doc #f)]
    [else
     (define-values (doc* d*) (apply-one doc i d #t))
     (values doc* (and d* (edit-change d* (buffer-edit-desc-inverse b0 d*) p0)))]))

;; 批量落回：依次施加 descs（**跳过守卫**），可选 pre-point 把视图 i 光标放回并 ensure-point。
;; 这是撤销/重放的唯一落回入口。
(define (document-apply-descs-trusted doc i descs [pre-point #f])
  (check-view-index 'document-apply-descs-trusted doc i)
  (define doc* (for/fold ([dd doc]) ([d (in-list descs)])
                 (define-values (dd* _) (apply-one dd i d #f))
                 dd*))
  (if pre-point
      (document-update-view doc* i (lambda (w) (window-ensure-point (window-set-point w pre-point))))
      doc*))

;;; ---------- 测试 ----------

(module+ test
  (define (w doc i) (document-window doc i))

  ;; P1 + 默认 'free
  (define-values (d2 i0) (document-add-view (document-open "hello\nworld") 10 40))
  (define-values (d2b i1) (document-add-view d2 10 40 (point 0 3)))
  (check-equal? i0 0)
  (check-equal? i1 1)
  (check-eq? (window-buffer (w d2b 0)) (window-buffer (w d2b 1)))
  (check-equal? (document-view-sync d2b 0) 'free)

  ;; free：编辑视图 0，视图 1 buffer 更新、光标跟随右移、视口不动
  (define-values (d3 ch) (document-edit d2b 0 (edit-insert-char #\X)))
  (check-equal? (edit-change-desc ch) (edit-desc (point 0 0) (point 0 0) "X"))
  (check-equal? (edit-change-inv ch) (edit-desc (point 0 0) (point 0 1) ""))
  (check-equal? (edit-change-pre-point ch) (point 0 0))
  (check-equal? (window-point (w d3 0)) (point 0 1))
  (check-equal? (document->string d3) "Xhello\nworld")
  (check-equal? (window-point (w d3 1)) (point 0 4))
  (check-equal? (window-top-line (w d3 1)) 0)

  ;; free：视图 1 接着编辑，看到视图 0 的最新结果
  (define-values (d4 _u1) (document-edit d3 1 (edit-insert-char #\Y)))
  (check-equal? (document->string d4) "XhelYlo\nworld")
  (check-equal? (window-point (w d4 0)) (point 0 1))

  ;; 光标落在被删区间 → 吸附起点
  (define-values (ea _u2) (document-add-view (document-open "abcdef") 10 40))
  (define-values (eb _u3) (document-add-view ea 10 40 (point 0 3)))
  (define-values (ec _u4) (document-edit eb 0 (edit-splice (point 0 0) (point 0 5) "")))
  (check-equal? (document->string ec) "f")
  (check-equal? (window-point (w ec 1)) (point 0 0))

  ;; follow：镜像编辑视图的最终视口（含 ensure-point 滚动）
  (define f0 (document-open "l0\nl1\nl2\nl3\nl4\nl5\nl6"))
  (define-values (f1 _u5) (document-add-view f0 3 10 (point 6 0)))
  (define f1b (document-update-view f1 0 (lambda (w) (window-set-top w 4))))
  (define-values (f2 _u6) (document-add-view f1b 3 10 (point 6 0) #:sync 'follow))
  (check-equal? (window-top-line (w f2 0)) 4)
  (define-values (f3 _u7) (document-edit f2 0 (edit-newline)))
  (check-equal? (window-point (w f3 0)) (point 7 0))
  (check-equal? (window-top-line (w f3 0)) 5)
  (check-equal? (window-top-line (w f3 1)) 5)
  (check-equal? (window-point (w f3 1)) (point 7 0))

  ;; follow 的几何独立性
  (define geo (document-open "l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9"))
  (define-values (geo1 _u8) (document-add-view geo 10 40 (point 0 0)))
  (define-values (geo2 _u9) (document-add-view geo1 3 40 (point 0 0) #:sync 'follow))
  (define geo3 (document-update-view geo2 0 (lambda (w) (window-set-point w (point 9 0)))))
  (define-values (geo4 _u10) (document-edit geo3 0 (edit-insert-char #\X)))
  (check-equal? (point-line (window-point (w geo4 1))) 9)
  (check-true (<= (window-top-line (w geo4 1)) 9
                  (+ (window-top-line (w geo4 1)) (sub1 (window-height (w geo4 1))))))

  ;; no-op
  (define-values (h0 _u11) (document-add-view (document-open "hello") 10 40))
  (define-values (h1 nd) (document-edit h0 0 (edit-backspace)))
  (check-false nd)
  (check-eq? h1 h0)

  ;; 导航经 document-update-view：目标视图变、策略保留、自动同步 follow
  (define-values (k0 _u12) (document-add-view (document-open "hello\nworld") 10 40))
  (define-values (k1 _u13) (document-add-view k0 10 40 (point 0 0) #:sync 'follow))
  (define k2 (document-update-view k1 0 window-right))
  (check-equal? (window-point (w k2 0)) (point 0 1))
  (check-equal? (window-point (w k2 1)) (point 0 1))
  (check-equal? (document-view-sync k2 1) 'follow)

  ;; 视图下标越界 → 报错
  (check-exn exn:fail? (lambda () (document-update-view k1 99 window-right)))
  (check-exn exn:fail? (lambda () (document-set-view-sync k1 99 'follow)))
  (check-exn exn:fail? (lambda () (document-window k1 99)))

  ;; 撤销语义：document-edit 的逆 + document-apply-descs-trusted
  (define rv0 (document-open "abc"))
  (define-values (rv1 _u14) (document-add-view rv0 3 20 (point 0 1)))
  (define-values (rv2 rv-ch) (document-edit rv1 0 (edit-insert "XY")))
  (check-equal? (document->string rv2) "aXYbc")
  (check-equal? (edit-change-desc rv-ch) (edit-desc (point 0 1) (point 0 1) "XY"))
  (check-equal? (edit-change-inv rv-ch) (edit-desc (point 0 1) (point 0 3) ""))
  (define rv3 (document-apply-descs-trusted rv2 0 (list (edit-change-inv rv-ch))
                                            (edit-change-pre-point rv-ch)))
  (check-equal? (document->string rv3) "abc")
  (check-equal? (window-point (w rv3 0)) (point 0 1))
  ;; 守卫 vs trusted
  (define ert (buffer-put-restrict (buffer-open "hello") 0 1 3 (restrict #t)))
  (define-values (er0 _u15) (document-add-view (document-of-buffer ert) 10 40 (point 0 2)))
  (define er-desc (edit-desc (point 0 2) (point 0 2) "Z"))
  (define-values (erg erg-ch) (document-edit er0 0 (lambda (_b _p) er-desc)))
  (check-equal? (document->string erg) "hello")
  (check-false erg-ch)
  (check-equal? (document->string (document-apply-descs-trusted er0 0 (list er-desc))) "heZllo")

  ;; 装饰写回：不丢视图、不换文本、光标不动
  (define dc0 (document-open "hello\nworld"))
  (define-values (dc1 _u16) (document-add-view dc0 10 40 (point 0 1)))
  (define dc2 (document-put-properties-many dc1 (list (list 0 0 5 'face 'bold))))
  (check-equal? (document-get-property dc2 0 2 'face) 'bold)
  (check-equal? (document->string dc2) "hello\nworld")
  (check-eq? (document-buffer dc2) (window-buffer (document-window dc2 0)))
  (check-equal? (window-point (document-window dc2 0)) (point 0 1))
  (define dc3 (document-put-restrict dc2 0 0 2 (restrict #t)))
  (check-true (document-read-only-at? dc3 0 1))
  (check-equal? (document-get-property dc3 0 2 'face) 'bold)
  (define dc4 (document-apply-patches dc3 (list (patch 'diag 0 0 (list (list 0 0 5 "err"))))))
  (check-equal? (document-get-property dc4 0 1 'diag) "err")
  (check-true (buffer-content-eq? (document-buffer dc3) (document-buffer dc4)))

  ;; D1 回归：free 视图 top 越界被夹回
  (define big (document-open (string-join (map number->string (range 20)) "\n")))
  (define-values (dv0 _u17) (document-add-view big 3 20 (point 0 0)))
  (define-values (dv1 _u18) (document-add-view dv0 3 20 (point 0 0)))
  (define dv2 (document-update-view dv1 1 (lambda (w) (window-set-top w 15))))
  (define-values (dv3 _u19) (document-edit dv2 0 (edit-splice (point 0 0) (point 19 0) "")))
  (check-equal? (buffer-line-count (document-buffer dv3)) 1)
  (check-equal? (window-top-line (document-window dv3 1)) 0)
  (check-true (vector? (window-vrows (document-window dv3 1))))

  (displayln "document.rkt: all tests passed"))
