#lang racket

;;; effects/engine.rkt —— core buffer / view 的唯一拥有者（不纯：可变引擎）
;;; layer  : effects
;;; effect : **引擎**：core buffer / view 的唯一可变拥有者
;;;            （engine-create-doc! / engine-create-view! / engine-remove-* / engine-apply!）

;;; 方案 B 的边界：
;;;   · State 只存 doc-id / view-id 与元数据；
;;;   · engine 持有真正的 core buffer / view 句柄；
;;   · 尺寸同步（engine-sync-view!）在**真的变了**之后会 view-ensure!，
;;     即“布局一变就把光标夹回窗口”；命令也可以显式发 ensure-view-effect；
;;;   · 命令只能通过 engine-view（只读查询）读，写操作一律走 effect；
;;;   · 解释器在边缘调用本模块。
;;;
;;; core 句柄只出现在 engine + paint（paint 负责 document slot / face 写回）。
;;; State 仍然只存 id；换引擎 / 做 headless replay / 多实例都不会污染 State。

(provide (struct-out engine)
         make-engine engine?
         engine-doc-buffer engine-view-object
         engine-doc-exists? engine-view-exists?
         engine-create-doc! engine-create-view!
         engine-remove-view! engine-remove-doc!
         engine-add-doc! engine-add-view!
         engine-apply!
         engine-effect?
         engine-sync-view! engine-sync-views! engine-ensure-view!
         engine-set-view-text!
         engine-replace-range!
         engine-set-face-layer!
         engine-set-face-layers!
         engine-attach-decors! engine-decors-attached?
         engine-paint-advance!
         ;; 只读查询接口（ctx.engine）
         (struct-out engine-view)
         make-engine-view
         engine-view-doc-text engine-view-doc-name engine-view-doc-version
         engine-view-view-text engine-view-view-readonly-at?
         engine-version=?
         engine-view-view-point engine-view-view-point-line engine-view-view-point-column
         engine-view-view-selections engine-view-view-cursor-position
         engine-view-view-screen-position->point
         engine-view-view-width engine-view-view-height engine-view-view-line-numbers?
         ;; open 请求
         (struct-out open-doc-spec)
         make-open-doc-spec
         open-doc-effect*)

(require "../../core/editor.rkt"
         (only-in "../../core/text/document.rkt" document-text)
         (only-in "../../core/editor/state.rkt" buffer-document)
         "../../core/text/base/track.rkt"
         (only-in "../../core/text/base/line.rkt" track-line-length)
         "../../core/text/base/change.rkt"
         "../../core/text/base/point.rkt"
         "../../core/text/base/range.rkt"
         "../base/effect.rkt"
         "paint.rkt")

;;; ════════════════════════ 引擎 ════════════════════════

(struct engine (docs views face-order doc-decors) #:mutable #:transparent)
;; docs       : (hash/c doc-id buffer)
;; views      : (hash/c view-id view)
;; face-order : (listof symbol)   层序（先低后高），由宿主在启动时设置
;; doc-decors : (hash/c doc-id (cons path (listof face-decor)))
;;              该文档适用的增量 decor；paint slot 才是状态真身。

(define (make-engine)
  (engine (hash) (hash) '() (hash)))

;;; ---------- face 层 / decor ----------

;; 层序：越靠后越“在上面”（后层的非 #f 分量覆盖前层）。
(define (engine-set-face-layers! e order)
  (set-engine-face-order! e order)
  (void))

;; 一次性静态层（补全选中行等）：写进 document 的 paint slot，文本编辑会自动平移。
(define (engine-set-face-layer! e did layer fills)
  (define b (engine-doc-buffer e did))
  (when b
    (paint-set-static-layer! b layer fills (engine-face-order e)))
  (void))

;; 给一个文档挂上适用的增量 decor（幂等）。
(define (engine-attach-decors! e did decors path)
  (define b (engine-doc-buffer e did))
  (when b
    (unless (hash-has-key? (engine-doc-decors e) did)
      (set-engine-doc-decors! e
                              (hash-set (engine-doc-decors e) did
                                        (cons path decors)))
      (paint-open! b decors path (engine-face-order e))))
  (void))

(define (engine-decors-attached? e did)
  (hash-has-key? (engine-doc-decors e) did))

;; 每帧 / 导航后推进光标相关 decor。cursor = (cons line col) | #f。
(define (engine-paint-advance! e vid)
  (define v (engine-view-object e vid))
  (when v
    (paint-advance! (view-buffer v)
                    (cons (view-point-line v) (view-point-column v))
                    (engine-face-order e)))
  (void))

(define (reset-paint-for-buffer! e b)
  (define did
    (for/first ([(did b*) (in-hash (engine-docs e))] #:when (eq? b* b)) did))
  (when did
    (define info (hash-ref (engine-doc-decors e) did #f))
    (paint-reset! b
                  (if info (cdr info) '())
                  (if info (car info) #f)
                  (engine-face-order e))))

(define (engine-doc-buffer e did)
  (hash-ref (engine-docs e) did #f))

(define (engine-view-object e vid)
  (hash-ref (engine-views e) vid #f))

(define (engine-doc-exists? e did) (and (engine-doc-buffer e did) #t))
(define (engine-view-exists? e vid) (and (engine-view-object e vid) #t))

(define (engine-add-doc! e did b)
  (set-engine-docs! e (hash-set (engine-docs e) did b))
  b)

(define (engine-add-view! e vid v)
  (set-engine-views! e (hash-set (engine-views e) vid v))
  v)

;;; ---------- 创建 ----------

;; 创建 buffer（不登记 view）。返回 buffer。
(define (engine-create-doc! e did name text)
  (define b (make-buffer text name))
  (engine-add-doc! e did b))

;; 在 doc 上创建 view；宽度 / 高度只是初始占位（真正的尺寸由 panel / panels-sync! 决定）。
(define (engine-create-view! e vid did
                             #:line-numbers? [line-numbers? #f]
                             #:width [width 1]
                             #:height [height 1])
  (define b (engine-doc-buffer e did))
  (unless b (error 'engine-create-view! "doc 不存在：~a" did))
  (define v (buffer-add-view! b width height #:line-numbers? line-numbers?))
  (engine-add-view! e vid v))

;;; ---------- 视口同步（panel 内容是尺寸真相） ----------

;; 把一个 view 的 viewport 落到内容区尺寸；尺寸不变则不写。
(define (engine-sync-view! e vid width height)
  (define v (engine-view-object e vid))
  (when v
    (define w (max 1 width))
    (define h (max 1 height))
    (unless (and (= w (view-width v)) (= h (view-height v)))
      (view-resize! v w h)
      ;; 尺寸变了（面板开关 / 拆分 / 隐藏）就把光标夹回窗口：
      ;; core 的 view-ensure! 会重算视口锚点，保证主光标可见。
      (view-ensure! v)))
  (void))

;; 显式“把某个 view 的光标夹进窗口”（命令 / 插件在布局变化后主动调用）
(define (engine-ensure-view! e vid)
  (define v (engine-view-object e vid))
  (when v (view-ensure! v))
  (void))

;; placements : (listof (list view-id width height)) 或 (listof (list view-id rect))
(define (engine-sync-views! e placements)
  (for ([p (in-list placements)])
    (define vid (car p))
    (define w (if (rect? (cadr p)) (rect-w (cadr p)) (cadr p)))
    (define h (if (rect? (cadr p)) (rect-h (cadr p)) (caddr p)))
    (engine-sync-view! e vid w h))
  (void))

;; 直接整篇写一个 view 的 buffer（状态栏同步 / prompt 前缀用）。
;; → (listof change)（整篇替换的变更描述）
(define (engine-set-view-text! e vid text)
  (define v (engine-view-object e vid))
  (cond
    [(not v) '()]
    [else
     (define b (view-buffer v))
     (define changes (buffer-set-document! b text))
     (reset-paint-for-buffer! e b)
     (define n (string-length text))
     (view-scroll-to-line! v 0)
     (view-scroll-to-column! v 0)
     (view-set-selections! v (selections-one (caret (point 0 n))) #:ensure? #f)
     (if (list? changes) changes '())]))

;;; ---------- 删除 ----------

(define (engine-remove-view! e vid)
  (define v (engine-view-object e vid))
  (when v
    (buffer-close-view! (view-buffer v) v)
    (set-engine-views! e (hash-remove (engine-views e) vid)))
  (void))

;; 删除 doc：先摘掉它所有 view，再关 buffer。
(define (engine-remove-doc! e did)
  (define b (engine-doc-buffer e did))
  (when b
    (define vids
      (for/list ([(vid v) (in-hash (engine-views e))]
                 #:when (eq? (view-buffer v) b))
        vid))
    (for ([vid (in-list vids)]) (engine-remove-view! e vid))
    (buffer-close! b)
    (set-engine-docs! e (hash-remove (engine-docs e) did))
    (set-engine-doc-decors! e (hash-remove (engine-doc-decors e) did)))
  (void))

;;; ════════════════════════ 写效果（引擎部分） ════════════════════════

(define (engine-effect? e)
  (or (edit-effect? e) (insert-text-effect? e) (set-text-effect? e)
      (set-input-prompt-effect? e)
      (select-effect? e) (scroll-effect? e) (nav-effect? e)
      (undo-effect? e) (redo-effect? e)))

;; 应用一个“只改 core”的 effect。
;; → (listof change)（无变化 / 非文本写 = '()；只读拒绝也是 '()，由调用方看 effect 语义）
;; 不是引擎 effect（open/close/io/…）-> error，调用方应先用 engine-effect? 判断。
(define (engine-apply! e effect)
  (match effect
    [(edit-effect vid op)
     (define v (need-view e vid))
     (define b (view-buffer v))
     (define changes (buffer-edit! b v op))
     (paint-write! b (engine-face-order e))
     (if (list? changes) changes '())]
    [(insert-text-effect vid text)
     (define v (need-view e vid))
     (define b (view-buffer v))
     (define changes (buffer-edit! b v (op-type text)))
     (paint-write! b (engine-face-order e))
     (if (list? changes) changes '())]
    [(set-text-effect vid text)
     (define v (need-view e vid))
     (define b (view-buffer v))
     (define changes (buffer-set-document! b text))
     (reset-paint-for-buffer! e b)
     (define n (string-length text))
     (view-scroll-to-line! v 0)
     (view-scroll-to-column! v 0)
     (view-set-selections! v (selections-one (caret (point 0 n))) #:ensure? #f)
     (if (list? changes) changes '())]
    [(set-input-prompt-effect vid prompt)
     (define v (need-view e vid))
     (define b (view-buffer v))
     (define n (string-length prompt))
     (define changes (buffer-set-document! b prompt))
     (reset-paint-for-buffer! e b)
     (buffer-readonly-range! b (range-of (point 0 0) (point 0 n)) #t)
     (view-scroll-to-line! v 0)
     (view-scroll-to-column! v 0)
     (view-set-selections! v (selections-one (caret (point 0 n))) #:ensure? #f)
     (if (list? changes) changes '())]
    [(select-effect vid sels)
     (define v (need-view e vid))
     (view-set-selections! v sels)
     (paint-advance! (view-buffer v)
                     (cons (view-point-line v) (view-point-column v))
                     (engine-face-order e))
     '()]
    [(scroll-effect vid delta)
     (view-scroll! (need-view e vid) delta)
     '()]
    [(nav-effect vid dir)
     (define v (need-view e vid))
     (apply-nav! v dir)
     (paint-advance! (view-buffer v)
                     (cons (view-point-line v) (view-point-column v))
                     (engine-face-order e))
     '()]
    [(undo-effect vid) (engine-undo-redo! e vid buffer-undo!)]
    [(redo-effect vid) (engine-undo-redo! e vid buffer-redo!)]
    [_ (error 'engine-apply! "不是引擎 effect：~a" effect)]))

;; 程序区间替换（补全把前缀换成候选）：也走 engine，保证 core 写只有一个入口。
(define (engine-replace-range! e vid r text)
  (define v (need-view e vid))
  (define b (view-buffer v))
  (define changes (buffer-replace-range! b r text))
  (paint-write! b (engine-face-order e))
  (if (list? changes) changes '()))

(define (engine-undo-redo! e vid proc)
  (define v (need-view e vid))
  (define b (view-buffer v))
  (define old-doc (buffer-document b))
  (define changed? (proc b))
  (cond
    [(not changed?) '()]
    [else
     (paint-write! b (engine-face-order e))
     (list (whole-change old-doc (buffer-document b)))]))

;; 整篇 change：undo/redo 没有逐条 changes，用“全脏”让 hook 自己重建。
(define (whole-range doc)
  (define t (document-text doc))
  (define n (track-length t))
  (if (zero? n)
      (range-of (point 0 0) (point 0 0))
      (let ([last (sub1 n)])
        (range-of (point 0 0) (point last (track-line-length t last))))))

(define (whole-change old new)
  (change (whole-range old) (whole-range new)))

(define (need-view e vid)
  (or (engine-view-object e vid)
      (error 'engine-apply! "view 不存在：~a" vid)))

(define (apply-nav! v dir)
  (case dir
    [(left)  (view-left! v)]
    [(right) (view-right! v)]
    [(up)    (view-up! v)]
    [(down)  (view-down! v)]
    [(home)  (view-home! v)]
    [(end)   (view-end! v)]
    [else    (error 'apply-nav! "未知方向：~a" dir)]))

;;; ════════════════════════ 只读接口 ════════════════════════
;;;
;;; ctx.engine 用这个包装，命令只能读。需要写 -> 返回 effect。
;;; 查询对不存在的 id 返回 #f / (values #f #f)，不抛异常（命令可安全 no-op）。

(struct engine-view (engine) #:transparent)

(define (make-engine-view e) (engine-view e))

(define (ev-buffer ev did)
  (engine-doc-buffer (engine-view-engine ev) did))

(define (ev-view ev vid)
  (engine-view-object (engine-view-engine ev) vid))

(define (engine-view-doc-text ev did)
  (define b (ev-buffer ev did))
  (and b (buffer-string b)))

(define (engine-view-doc-name ev did)
  (define b (ev-buffer ev did))
  (and b (buffer-name b)))

(define (engine-view-view-text ev vid)
  (define v (ev-view ev vid))
  (and v (buffer-string (view-buffer v))))

(define (engine-view-view-readonly-at? ev vid line col)
  (define v (ev-view ev vid))
  (and v (view-readonly-at? v line col)))

;; 当前文档版本 = core 的 opaque document token。
;; 用 engine-version=?（eq?）比较：编辑 -> 新 token；undo 回保存点 -> 恢复同一 token。
(define (engine-view-doc-version ev did)
  (define b (ev-buffer ev did))
  (and b (buffer-version b)))

(define (engine-version=? a b) (buffer-version=? a b))

(define (engine-view-view-point ev vid)
  (define v (ev-view ev vid))
  (and v (view-point v)))

(define (engine-view-view-point-line ev vid)
  (define v (ev-view ev vid))
  (and v (view-point-line v)))

(define (engine-view-view-point-column ev vid)
  (define v (ev-view ev vid))
  (and v (view-point-column v)))

(define (engine-view-view-selections ev vid)
  (define v (ev-view ev vid))
  (and v (view-selections v)))

(define (engine-view-view-cursor-position ev vid)
  (define v (ev-view ev vid))
  (if v (view-cursor-screen-position v) (values #f #f)))

(define (engine-view-view-screen-position->point ev vid row col)
  (define v (ev-view ev vid))
  (if v (view-screen-position->point v row col) (values #f #f)))

(define (engine-view-view-width ev vid)
  (define v (ev-view ev vid))
  (and v (view-width v)))

(define (engine-view-view-height ev vid)
  (define v (ev-view ev vid))
  (and v (view-height v)))

(define (engine-view-view-line-numbers? ev vid)
  (define v (ev-view ev vid))
  (and v (view-line-numbers? v)))

;;; ════════════════════════ open-doc 请求 ════════════════════════

(struct open-doc-spec (name text mode path line-numbers? keymaps) #:transparent)

(define (make-open-doc-spec name text
                            #:mode [mode 'text]
                            #:path [path #f]
                            #:line-numbers? [line-numbers? #f]
                            #:keymaps [keymaps '()])
  (open-doc-spec name text mode path line-numbers? keymaps))

;; 便捷构造 effect：k : (state doc-id view-id -> transition)。
(define (open-doc-effect* spec k)
  (open-doc-effect spec k))
