#lang racket

(require "../text/point.rkt"
         "../text/content.rkt"
         "../text/buffer.rkt"
         "window.rkt"
         "view.rkt"
         rackunit)

;;; document.rkt —— 共享 buffer 的多窗口同步
;;;
;;; 背景：buffer 是不可变快照；window 持有「buffer 引用 + 自己的光标」。
;;; 多个 window 共享同一 buffer 时，直接让它们各自编辑会出三类问题：
;;;
;;;   P1 分叉      A 编辑后 B 仍引用旧 buffer —— 文档被悄悄分成两份
;;;   P2 光标失效  A 在 B 光标之前增删，B 的 point 不再指向原文本
;;;   P3 丢失更新  B 基于旧 buffer 编辑，覆盖 A 的结果
;;;
;;; document 是「单一事实源」：一个 buffer + 一组视图（window），
;;; 所有编辑都经 document-edit 串行化，编辑后所有视图统一 rebase。
;;;
;;; 每个视图带一个同步策略（sync），决定「别的视图编辑后，我的滚动状态怎么变」：
;;;
;;;   'free   视口独立（top-line/left-col/top-seg 钉住不动），光标随文本修正。
;;;           适合「看 API 签名写代码」这类参考视图：编辑发生在参考区之外，视口不漂。
;;;   'follow 镜像编辑视图：视口 + 光标都复制自「正在编辑的那个视图」。
;;;           适合两个窗口一起编辑同一处，一方始终跟随另一方。
;;;
;;; 编辑发生所在的那个视图永远是固定行为：光标推进到插入后，document-edit 内部
;;; 调用 window-ensure-point 让光标可见（这也是 follow 能对齐最终 top-line 的前提）。
;;;
;;; 纯函数式：document 本身不可变，随调用方状态一起 threading。
;;; 不变量：任一 document 内，所有 (window-buffer v) 都 eq? 于 (document-buffer doc)。

(provide
 (struct-out view)
 (struct-out document)
 document-open
 document-of-buffer
 document->string
 document->lines
 document-view-count
 document-view-ref
 document-add-view
 document-window
 document-view-sync
 document-set-view-sync
 document-update-view
 document-update-view-synced
 document-sync-followers
 document-edit
 document-apply-edit
 document-apply-descs-trusted)

;; 一个视图 = 窗口快照 + 同步策略
(struct view (window sync) #:transparent)
;; sync : 'free | 'follow

;; buffer : buffer         当前共享 buffer（唯一事实源）
;; views  : (listof view)  视图，顺序稳定，靠下标索引
(struct document (buffer views) #:transparent)

;; sync 取值校验（'free | 'follow）
(define (check-sync who s)
  (unless (memq s '(free follow))
    (error who "sync must be 'free or 'follow, got ~a" s)))

(define (document-open s) (document (buffer-open s) '()))

;; 从已配置好的 buffer 构造（如已做语法高亮 / read-only 标记的 buffer）
(define (document-of-buffer b) (document b '()))

;; 文档的读入口（ARCHITECTURE §12）：消费者读文本不必再下探 buffer-*。
;; 想拿真正的 buffer（插件/属性等）仍走 document-buffer 这个访问器。
(define (document->string doc) (buffer->string (document-buffer doc)))
(define (document->lines doc) (buffer->lines (document-buffer doc)))

(define (document-view-count doc) (length (document-views doc)))

;; 注册一个视图。w 的 buffer 字段被替换成共享 buffer（丢弃 w 原来带的 buffer）。
;; p    = 初始光标（不传则用 w 自己的 point，但会被共享 buffer 夹紧）
;; sync = 该视图的同步策略，默认 'free
;; 返回 (values document index)。
;; 注意顺序：先换 buffer 再设 point，避免 point 被 w 原带的 buffer 提前夹紧。
(define (document-add-view doc w [p #f] #:sync [sync 'free])
  (check-sync 'document-add-view sync)
  (define w* (window-set-buffer w (document-buffer doc)))
  (define w+ (window-clamp-view (if p (window-set-point w* p) w*)))
  (define idx (document-view-count doc))   ; 新下标 = 旧数量
  (values
   (struct-copy document doc
     [views (append (document-views doc) (list (view w+ sync)))])
   idx))

;; 视图索引校验：取/改视图的函数都经这里，越界一律报错（原来 update-view/set-view-sync
;; 静默返回原 doc，而 document-window 是 list-ref 抛 —— 同类操作两副面孔，见 §10.3 A3）。
(define (check-view-index who doc i)
  (unless (and (exact-nonnegative-integer? i) (< i (document-view-count doc)))
    (error who "视图下标越界: ~a（该 document 有 ~a 个视图）" i (document-view-count doc))))

;; 取第 i 个视图（完整 view：window + sync）。命名同 buffer-line-ref：按 index 取。
(define (document-view-ref doc i)
  (check-view-index 'document-view-ref doc i)
  (list-ref (document-views doc) i))

;; 便捷：取第 i 个视图的 window（已与共享 buffer 同步），最常用
(define (document-window doc i) (view-window (document-view-ref doc i)))

(define (document-view-sync doc i) (view-sync (document-view-ref doc i)))

;; 运行时改第 i 个视图的策略
(define (document-set-view-sync doc i sync)
  (check-sync 'document-set-view-sync sync)
  (check-view-index 'document-set-view-sync doc i)
  (struct-copy document doc
    [views (for/list ([j (in-naturals)] [v (in-list (document-views doc))])
             (if (= j i) (struct-copy view v [sync sync]) v))]))

;; 更新第 i 个视图的 window（导航/滚动等纯 window 变换 f : window -> window），策略不动。
;; 结果一律夹回合法域（视口不变量，见 view.rkt window-clamp-view / ARCHITECTURE §10.3 D1）。
(define (document-update-view doc i f)
  (check-view-index 'document-update-view doc i)
  (struct-copy document doc
    [views (for/list ([j (in-naturals)] [v (in-list (document-views doc))])
             (if (= j i) (struct-copy view v [window (window-clamp-view (f (view-window v)))]) v))]))

;; 改第 i 个视图并**保持 follow 视图一致**（= 上面两步一次做完）。
;; 语义平行于 document-edit：「这次变化由视图 i 发起，其余 follow 视图必须跟它一致」。
;; 需要「改视图但**不**镜像」（如改尺寸）时仍用 document-update-view（ARCHITECTURE §11.2 ②）。
(define (document-update-view-synced doc i f)
  (document-sync-followers (document-update-view doc i f) i))

;; 把第 i 视图的 point+viewport 对齐到所有 'follow 视图（编辑后的导航/滚动后调用）。
;; 编辑路径在 document-edit 内部已同步 follow，这里用于导航/滚动等非编辑变化。
(define (document-sync-followers doc i)
  (define lead (document-window doc i))
  (struct-copy document doc
    [views (for/list ([j (in-naturals)] [v (in-list (document-views doc))])
             (if (and (not (= j i)) (eq? (view-sync v) 'follow))
                 (view (rebase-follow (view-window v) lead) 'follow)
                 v))]))

;;; ---------- rebase 策略 ----------

;; 'free：光标随文本映射（落在删除区 → 吸附起点），视口三个字段完全不动
(define (rebase-free w new-buffer desc)
  (define p (window-point w))
  (define p* (or (edit-desc-map-position desc (point-line p) (point-col p))
                 (point (edit-desc-s-line desc) (edit-desc-s-col desc))))
  (window-set-point (window-set-buffer w new-buffer) p*))

;; 'follow：光标 + 视口锚点复制自编辑视图，**然后按自己的几何 ensure-point**。
;;   几何相同时 ensure-point 无事可做（编辑视图的 point 本就在其几何内可见）→ 行为不变；
;;   几何不同（如 follower 更矮）或 mode 不同时，自动退化为「跟着光标，视口自己夹紧」，
;;   不会把光标丢到自己的可见区之外。height/width/mode 始终是视图自身的，不复制。
(define (rebase-follow w editing)
  (window-ensure-point
   (struct-copy window w
     [buffer   (window-buffer   editing)]
     [point    (window-point    editing)]
     [top-line (window-top-line editing)]
     [left-col (window-left-col editing)]
     [top-seg  (window-top-seg  editing)])))

;;; ---------- 编辑 ----------
;;; 一条核心 + 三个对外入口：
;;;   edit-and-rebase            私有机制：施加一次编辑 + 按各视图 sync 统一 rebase
;;;   document-edit              编辑入口：核心 + 捕捉这次编辑的材料（edit-change）
;;;   document-apply-edit        单条 desc 落回，过守卫（程序编辑）
;;;   document-apply-descs-trusted  批量 desc 落回，跳过守卫（撤销/重放）
;;; 分工的判据：rebase 是机制；change 是「编辑入口」的职责——落回路径没有新事实要捕捉，
;;; 也就不该为它多算一次逆。

;; 核心机制：把 edit-fn 施加到视图 i（光标取自该视图），再按各视图的 sync rebase。
;; 返回 (values document (or/c #f edit-desc))；#f = no-op / 被 read-only 拒（document 原样）。
(define (edit-and-rebase doc i edit-fn)
  (define b0 (document-buffer doc))
  (define w  (document-window doc i))
  (define p  (window-point w))
  (define-values (b* desc) (edit-fn b0 (point-line p) (point-col p)))
  (cond
    [(not desc) (values doc #f)]     ; no-op / read-only 拒绝
    [else
     ;; 编辑视图：光标推进到插入后，并 ensure-point 让光标可见。
     ;; 必须先 settle 编辑视图的最终 top-line，再让 'follow 复制——
     ;; 否则 follow 复制的是滚动前的旧 top-line，会差一行 / 只跟下滚不跟上滚。
     (define editing
       (window-ensure-point
        (struct-copy window w [buffer b*] [point (edit-desc-after-position desc)])))
     ;; 重建视图列表：每个视图保留自己的 sync，只换 window
     (define views*
       (for/list ([j (in-naturals)] [v (in-list (document-views doc))])
         (define sync (view-sync v))
         (define w*
           (window-clamp-view
            (if (= j i)
                editing
                (case sync
                  [(free)   (rebase-free   (view-window v) b* desc)]
                  [(follow) (rebase-follow (view-window v) editing)]
                  [else (error 'document-edit "unknown sync ~a" sync)]))))
         (view w* sync)))
     (values (document b* views*) desc)]))

;; 在第 i 个视图的光标处做一次编辑。**唯一的编辑入口**——要不要撤销不改变入口，
;; 只改变你对第二值的处理（要撤销就收下 change 存进账本，不要就丢掉）。
;; 返回 (values document (or/c #f edit-change))；#f = 什么都没发生。
;; change 的逆用**编辑前**的 buffer 导出，故 §9.3 那个「用后态 buffer 求逆、只在删除
;; 路径写坏历史」的静默坑不可达。**不记任何历史** —— 入不入栈由消费层决定（§9.4）。
;; edit-fn : buffer line col -> (values buffer edit-desc)（构造器见 buffer.rkt 的 edit-* 家族）
(define (document-edit doc i edit-fn)
  (define b0 (document-buffer doc))
  (define p0 (window-point (document-window doc i)))
  (define-values (doc* desc) (edit-and-rebase doc i edit-fn))
  (values doc* (and desc (edit-change desc (buffer-edit-desc-inverse b0 desc) p0))))

;; desc 形状的编辑入口：施加一条**自带坐标**的 desc（程序编辑的落点）。
;; 与 document-edit 的分工：后者是「在光标处编辑」，本函数是「照 desc 施加」——
;; 两者走同一个漏斗（编辑视图推进光标 + ensure-point，其余视图按自己的 sync rebase），
;; 所以这边同样捕捉 change。要跳过 read-only 守卫请用下面的批量入口。
(define (document-apply-edit doc i desc)
  (document-edit doc i (lambda (b _l _c) (buffer-apply-edit b desc))))

;; 批量落回：依次施加 descs（**跳过 read-only 守卫** —— 记录在案的编辑当年都过了守卫，
;; 不该被**事后**才加的约束挡住）。给了 pre-point 就把视图 i 的光标放回那里并
;; ensure-point，最后对齐 follow 视图。**撤销/重放的唯一落回入口**：
;;   撤销 → (document-apply-descs-trusted doc i (step-undo-descs st) (step-point st))
;;   重放 → (document-apply-descs-trusted doc i (step-replay-descs st))
;; 不产出 change：落回不是编辑，没有新事实要捕捉（用 edit-and-rebase 而非 document-edit）。
(define (document-apply-descs-trusted doc i descs [pre-point #f])
  (define doc*
    (for/fold ([d doc]) ([x (in-list descs)])
      (define-values (d* _)
        (edit-and-rebase d i (lambda (b _l _c) (buffer-apply-edit-trusted b x))))
      d*))
  (if pre-point
      (document-update-view-synced
       doc* i (lambda (w) (window-ensure-point (window-set-point w pre-point))))
      doc*))

;;; ---------- 测试 ----------

(module+ test
  (define (w doc i) (document-window doc i))

  ;; P1 + 默认策略：两个视图共享同一 buffer，默认 'free
  (define d0 (document-open "hello\nworld"))
  (define-values (d1 i0) (document-add-view d0 (make-window 10 40)))
  (define-values (d2 i1) (document-add-view d1 (make-window 10 40) (point 0 3)))
  (check-equal? i0 0)
  (check-equal? i1 1)
  (check-eq? (document-buffer d2) (window-buffer (w d2 0)))
  (check-eq? (window-buffer (w d2 0)) (window-buffer (w d2 1)))
  (check-equal? (window-point (w d2 1)) (point 0 3))
  (check-equal? (document-view-sync d2 0) 'free)
  (check-equal? (document-view-sync d2 1) 'free)

  ;; free：视图 0 插入后，视图 1 的 buffer 更新、光标跟随右移、视口不动
  (define-values (d3 dd) (document-edit d2 0 (edit-char #\X)))
  (check-equal? (edit-change-desc dd) (edit-desc 0 0 0 0 "X"))
  (check-equal? (edit-change-inv dd) (edit-desc 0 0 0 1 ""))
  (check-equal? (edit-change-pre-point dd) (point 0 0))
  (check-equal? (window-point (w d3 0)) (point 0 1))                     ; 编辑视图光标推进
  (check-equal? (buffer->string (window-buffer (w d3 1))) "Xhello\nworld") ; 不分叉
  (check-equal? (window-point (w d3 1)) (point 0 4))                     ; 3 → 4 光标随文本
  (check-equal? (window-top-line (w d3 1)) 0)                            ; 视口钉住不动

  ;; free：视图 1 接着编辑，看到视图 0 的最新结果（不丢更新）
  (define-values (d4 _d4) (document-edit d3 1 (edit-char #\Y)))
  (check-equal? (buffer->string (document-buffer d4)) "XhelYlo\nworld")
  (check-equal? (window-point (w d4 1)) (point 0 5))
  (check-equal? (window-point (w d4 0)) (point 0 1))                     ; 另一视图光标不动

  ;; 光标落在被删区间内 → 吸附到区间起点
  (define e0 (document-open "abcdef"))
  (define-values (e1 _e1) (document-add-view e0 (make-window 10 40)))
  (define-values (e2 _e2) (document-add-view e1 (make-window 10 40) (point 0 3)))
  (define-values (e3 _e3)
    (document-edit e2 0 (lambda (b l c) (buffer-splice b 0 0 0 5 ""))))  ; 删 [0,5)
  (check-equal? (buffer->string (document-buffer e3)) "f")
  (check-equal? (window-point (w e3 1)) (point 0 0))                     ; 被删 → 吸附起点

  ;; follow：视图 1 镜像视图 0 的「最终」视口（含 ensure-point 滚动），不差行
  ;; 视图 0：高 3，光标在底行 (6,0)，滚到 top-line 4（光标恰在视口底行）
  (define f0 (document-open "l0\nl1\nl2\nl3\nl4\nl5\nl6"))
  (define-values (f1 _f1)
    (document-add-view f0 (make-window 3 10) (point 6 0)))
  (define f1b (document-update-view f1 0 (lambda (w) (window-set-top w 4))))
  (define-values (f2 _f2)
    (document-add-view f1b (make-window 3 10) (point 6 0) #:sync 'follow))
  (check-equal? (document-view-sync f2 1) 'follow)
  (check-equal? (window-top-line (w f2 0)) 4)
  ;; 底行回车 → 光标到 (7,0)，视口下滚 → top-line 5；follow 必须对齐到 5（不差行）
  (define-values (f3 _f3) (document-edit f2 0 (edit-newline)))
  (check-equal? (window-point (w f3 0)) (point 7 0))
  (check-equal? (window-top-line (w f3 0)) 5)     ; 编辑视图下滚一行
  (check-equal? (window-top-line (w f3 1)) 5)     ; follow 同步下滚，不差行
  (check-equal? (window-point (w f3 1)) (point 7 0))
  ;; 向上滚：把视图 0 光标挪到顶行 (5,0)（导航后同步 follow），backspace 合并到上一行
  ;; → 光标到 (4,2)，视口上滚 → top-line 4；follow 同步上滚
  (define f4 (document-update-view f3 0 (lambda (w) (window-set-point w (point 5 0)))))
  (define f5 (document-sync-followers f4 0))       ; 导航后同步 follow
  (check-equal? (window-point (w f5 0)) (point 5 0))
  (check-equal? (window-point (w f5 1)) (point 5 0))
  (define-values (f6 _f6) (document-edit f5 0 (edit-backspace)))
  (check-equal? (window-point (w f6 0)) (point 4 2))   ; 合并到 line4 行尾
  (check-equal? (window-top-line (w f6 0)) 4)          ; 编辑视图上滚一行
  (check-equal? (window-top-line (w f6 1)) 4)          ; follow 同步上滚
  (check-equal? (window-point (w f6 1)) (point 4 2))

  ;; 运行时改策略
  (define-values (g0 _g0) (document-add-view (document-open "hello\nworld") (make-window 10 40)))
  (define-values (g1 _g1) (document-add-view g0 (make-window 10 40)))
  (check-equal? (document-view-sync g1 1) 'free)
  (define g2 (document-set-view-sync g1 1 'follow))
  (check-equal? (document-view-sync g2 1) 'follow)

  ;; follow 的几何独立性：两个视图几何**不同**时，镜像后光标仍在自己可见区内
  (define geo (document-open "l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9"))
  (define-values (geo1 _gi0) (document-add-view geo (make-window 10 40) (point 0 0)))
  (define-values (geo2 _gi1) (document-add-view geo1 (make-window 3 40)
                                                (point 0 0) #:sync 'follow))
  ;; 编辑视图光标移到最底行，再编辑（它的视口不会滚：line 9 在 10 行内可见）
  (define geo3 (document-update-view geo2 0 (lambda (w) (window-set-point w (point 9 0)))))
  (define-values (geo4 _gd) (document-edit geo3 0 (edit-char #\X)))
  (check-equal? (window-top-line (document-window geo4 0)) 0)
  (define w-follow (document-window geo4 1))
  (check-equal? (point-line (window-point w-follow)) 9)          ; 光标跟上了
  (check-true (<= (window-top-line w-follow) 9                    ; 且在自己 3 行可见区内
                  (+ (window-top-line w-follow) (sub1 (window-height w-follow)))))

  ;; no-op：desc #f，document 原样返回
  (define-values (h0 _h0) (document-add-view (document-open "hello") (make-window 10 40)))
  (define-values (h1 nd) (document-edit h0 0 (edit-backspace)))   ; 视图 0 在 (0,0)，backspace 无操作
  (check-false nd)
  (check-eq? h1 h0)

  ;; 导航经 document-update-view：光标变化只在目标视图，且策略保留
  (define-values (k0 _k0) (document-add-view (document-open "hello\nworld") (make-window 10 40)))
  (define-values (k1 _k1) (document-add-view k0 (make-window 10 40) (point 0 0) #:sync 'follow))
  (define k2 (document-update-view k1 1 window-right))
  (check-equal? (window-point (w k2 1)) (point 0 1))
  (check-equal? (window-point (w k2 0)) (point 0 0))
  (check-equal? (document-view-sync k2 1) 'follow)
  (check-eq? (window-buffer (w k2 0)) (window-buffer (w k2 1)))

  ;; A3 回归：视图索引越界 → 统一报错（原来 update-view/set-view-sync 静默返回原 doc）
  (define va (document-open "hello"))
  (define-values (vb _vi) (document-add-view va (make-window 10 40)))
  (check-exn exn:fail? (lambda () (document-update-view vb 99 window-right)))
  (check-exn exn:fail? (lambda () (document-set-view-sync vb 99 'follow)))
  (check-exn exn:fail? (lambda () (document-window vb 99)))

  ;; ② document-update-view-synced = update-view + sync-followers（一步）
  (check-equal? (window-point (w (document-update-view-synced k1 0 window-right) 0)) (point 0 1))
  (check-equal? (window-point (w (document-update-view-synced k1 0 window-right) 1)) (point 0 1))  ; follow 跟上
  (check-equal? (window-buffer (w (document-update-view-synced k1 0 window-right) 0))
                (window-buffer (w (document-update-view-synced k1 0 window-right) 1)))

  ;; ③ document-edit：一次给出「新 document + 这次编辑的完整材料」
  (define rv0 (document-open "abc"))
  (define-values (rv1 _rvi) (document-add-view rv0 (make-window 3 20) (point 0 1)))
  (define-values (rv2 rv-ch) (document-edit rv1 0 (edit-insert "XY")))
  (check-equal? (buffer->string (document-buffer rv2)) "aXYbc")
  (check-equal? (edit-change-desc rv-ch) (edit-desc 0 1 0 1 "XY"))
  (check-equal? (edit-change-inv  rv-ch) (edit-desc 0 1 0 3 ""))   ; 逆 = 删掉刚插入的 "XY"
  (check-equal? (edit-change-pre-point rv-ch) (point 0 1))         ; 视图 0 编辑前的光标
  ;; 撤销 = 把逆当 desc 施加 → 精确回到编辑前（文本 + 光标）
  (define-values (rv3 _rv3c) (document-apply-edit rv2 0 (edit-change-inv rv-ch)))
  (check-equal? (buffer->string (document-buffer rv3)) "abc")
  (check-equal? (window-point (w rv3 0)) (edit-change-pre-point rv-ch))
  ;; no-op：document 原样，**整个 change 是 #f**（不再有「desc = #f 但 pre-point 照给」）
  (define-values (rv4 rv-ch2) (document-edit rv1 0 (lambda (b _l _c) (values b #f))))
  (check-eq? rv4 rv1)
  (check-false rv-ch2)

  ;; D1 回归：free 视图 top 越界后不空白、不崩
  ;; （原来：wrap → window->screen 抛 vector-ref；clip → 静默全空白）
  (define big (document-open (string-join (map number->string (range 20)) "\n")))
  (define-values (dv0 _dv0) (document-add-view big (make-window 3 20) (point 0 0)))
  (define-values (dv1 _dv1) (document-add-view dv0 (make-window 3 20) (point 0 0)))
  ;; wrap：先把 free 视图滚到 top 15，再由视图 0 删掉 19 行
  (define dv2 (document-update-view dv1 1 (lambda (w) (window-set-mode (window-set-top w 15) 'wrap))))
  (check-equal? (window-top-line (document-window dv2 1)) 15)      ; 没越界时不动
  (define-values (dv3 _dd) (document-edit dv2 0 (lambda (b _l _c) (buffer-splice b 0 0 19 0 ""))))
  (check-equal? (buffer-line-count (document-buffer dv3)) 1)
  (check-equal? (window-top-line (document-window dv3 1)) 0)       ; 夹回合法域
  (check-true (vector? (window-vrows (document-window dv3 1))))    ; 不再抛 vector-ref
  ;; clip：同样越界 → 原来静默全空白
  (define dc2 (document-update-view dv1 1 (lambda (w) (window-set-top w 15))))
  (define-values (dc3 _dc) (document-edit dc2 0 (lambda (b _l _c) (buffer-splice b 0 0 19 0 ""))))
  (check-equal? (window-top-line (document-window dc3 1)) 0)
  (check-equal? (vrow-line (vector-ref (window-vrows (document-window dc3 1)) 0)) 0)

  ;; B 组：desc 形状入口
  (define ea (document-open "hello\nworld"))
  (define-values (eb _eb) (document-add-view ea (make-window 10 40) (point 0 1)))
  (define-values (ec ec-ch) (document-edit eb 0 (edit-insert "XY")))
  (check-equal? (buffer->string (document-buffer ec)) "hXYello\nworld")   ; 插在光标 (0,1) 处
  ;; document-apply-edit：照 desc 施加一次 → 与产生该 desc 的编辑等价（含光标落点）
  (define ec-desc (edit-change-desc ec-ch))
  (define-values (ed ed-ch) (document-apply-edit ec 0 ec-desc))
  (check-equal? (edit-change-desc ed-ch) ec-desc)
  (check-equal? (buffer->string (document-buffer ed)) "hXYXYello\nworld")
  (check-equal? (window-point (document-window ed 0)) (window-point (document-window ec 0)))
  ;; 守卫/trusted 的分工：document-apply-edit **过守卫** → 拒绝 read-only 内的 desc；
  ;; 批量落回入口**跳过守卫** → 施加（撤销/重放靠它）
  (define ert (buffer-put-restrict (buffer-open "hello") 0 1 3 (restrict #t)))
  (define-values (er0 _er0) (document-add-view (document-of-buffer ert) (make-window 10 40) (point 0 2)))
  (define er-desc (edit-desc 0 2 0 2 "Z"))
  (define-values (erg erg-ch) (document-apply-edit er0 0 er-desc))
  (check-equal? (buffer->string (document-buffer erg)) "hello")   ; 守卫拒绝：文本未变
  (check-false erg-ch)                                            ; 且什么都没发生
  (define er1 (document-apply-descs-trusted er0 0 (list er-desc)))
  (check-equal? (buffer->string (document-buffer er1)) "heZllo")

  ;; C 组：批量落回 + 光标恢复（撤销/重放的形状）
  ;; 两条 desc 一次落回；**逆序**施加才闭合（逆的次序与正序相反），光标显式放回该步之前
  (define cb0 (document-open "abcdef"))
  (define-values (cb1 _cbi) (document-add-view cb0 (make-window 4 20) (point 0 2)))
  (define-values (cb2 cb-ch1) (document-edit cb1 0 (edit-delete)))   ; 删 'c'
  (define-values (cb3 cb-ch2) (document-edit cb2 0 (edit-delete)))   ; 删 'd'
  (check-equal? (buffer->string (document-buffer cb3)) "abef")
  (define cb4 (document-apply-descs-trusted
               cb3 0 (list (edit-change-inv cb-ch2) (edit-change-inv cb-ch1))
               (edit-change-pre-point cb-ch1)))
  (check-equal? (buffer->string (document-buffer cb4)) "abcdef")
  (check-equal? (window-point (w cb4 0)) (point 0 2))
  ;; 不给 pre-point：光标由最后一条 desc 推导（重放的形状——最后一条是纯插入 → 插入之后）
  (define cb5 (document-apply-descs-trusted cb1 0 (list (edit-change-desc cb-ch1))))
  (check-equal? (buffer->string (document-buffer cb5)) "abdef")
  (check-equal? (window-point (w cb5 0)) (point 0 2))

  ;; §12：文档读入口
  (check-equal? (document->string (document-open "a\nb")) "a\nb")
  (check-equal? (document->lines (document-open "a\nb")) '("a" "b"))
  (check-equal? (document->lines (document-open "")) '(""))

  (displayln "document.rkt: all tests passed"))
