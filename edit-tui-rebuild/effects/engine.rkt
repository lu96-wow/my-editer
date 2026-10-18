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
;;; 本模块是 rebuild 里**唯一** require core/editor.rkt 的地方（测试除外）。
;;; 这样换引擎 / 做 headless replay / 多实例都不会污染 State。

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
         engine-set-face-layer!
         engine-set-face-layers!
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
         "../base/effect.rkt"
         "../model/face-layer.rkt")

;;; ════════════════════════ 引擎 ════════════════════════

(struct engine (docs views face-layers face-order) #:mutable #:transparent)
;; docs       : (hash/c doc-id buffer)
;; views      : (hash/c view-id view)
;; face-layers: (make-hasheq) buffer -> (hash/c symbol (listof fill))   每层的 fills
;; face-order : (listof symbol)   层序（先低后高），由宿主在启动时设置
;;
;; 为什么以 **buffer** 为键而不是 doc-id：文本一变就要把该 buffer 的层作废，
;; 而 `engine-apply!` 手上只有 view（能拿到 buffer，拿不到 doc-id）。

(define (make-engine)
  (engine (hash) (hash) (make-hasheq) '()))

;;; ---------- face 层 ----------

;; 层序：越靠后越“在上面”（后层的非 #f 分量覆盖前层）。
(define (engine-set-face-layers! e order)
  (set-engine-face-order! e order)
  (void))

(define (layers-of e b) (hash-ref (engine-face-layers e) b (hash)))

;; 设置某个 buffer 的某层 fills，然后**合成所有层**并整篇写回 core 的 face 端口。
;;
;; 为什么整篇写：core 的 face 端口是“每格一个值”，分层是框架的概念；
;; 合成后只剩一张 face 表，写回仍然只有一次 `buffer-face-batch!`。
;;
;; 坐标来自“提交这个 job 时的文本”；回来时文本可能又变了 —— 所以：
;;   · 文本一变就清层（见 `engine-clear-face-layers!`），旧层不会残留；
;;   · 写回前再 `clip-fills` 夹一遍（防御：coord 一律不能越出当前文本）。
(define (engine-set-face-layer! e did layer fills)
  (define b (engine-doc-buffer e did))
  (when b
    (hash-set! (engine-face-layers e) b (hash-set (layers-of e b) layer fills))
    (write-faces! e b))
  (void))

;; 文本变了：这个 buffer 的层全部作废（fill 的坐标属于旧文本），并清掉 core 的 face。
(define (engine-clear-face-layers! e b)
  (when b
    (hash-remove! (engine-face-layers e) b)
    (buffer-face-all! b #f))
  (void))

(define (write-faces! e b)
  (buffer-face-all! b #f)
  (buffer-face-batch! b (clip-fills b (compose-layers (engine-face-order e) (layers-of e b)))))

;; fills 夹到当前文本：行越界丢弃，列越界夹到行尾，空区间去掉。
(define (clip-fills b fills)
  (define t (document-text (buffer-document b)))
  (define n (track-length t))
  (define (linelen i) (track-line-length t i))
  (filter values
          (for/list ([f (in-list fills)]
                     #:when (< (list-ref f 0) n))
    (define l0 (list-ref f 0))
    (define l1 (min (list-ref f 2) (sub1 n)))
    (define c0 (min (list-ref f 1) (linelen l0)))
    (define c1 (if (= l1 (list-ref f 2))
                   (min (list-ref f 3) (linelen l1))
                   (linelen l1)))
            (and (< c0 c1) (list l0 c0 l1 c1 (list-ref f 4))))))

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
(define (engine-set-view-text! e vid text)
  (define v (engine-view-object e vid))
  (when v
    (define n (string-length text))
    (buffer-set-document! (view-buffer v) text)
    (view-scroll-to-line! v 0)
    (view-scroll-to-column! v 0)
    (view-set-selections! v (selections-one (caret (point 0 n))) #:ensure? #f))
  (void))

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
    (set-engine-docs! e (hash-remove (engine-docs e) did)))
  (void))

;;; ════════════════════════ 写效果（引擎部分） ════════════════════════

(define (engine-effect? e)
  (or (edit-effect? e) (insert-text-effect? e) (set-text-effect? e)
      (set-input-prompt-effect? e)
      (select-effect? e) (scroll-effect? e) (nav-effect? e)
      (undo-effect? e) (redo-effect? e)))

;; 应用一个“只改 core”的 effect。返回 void。
;; 不是引擎 effect（open/close/io/…）-> error，调用方应先用 engine-effect? 判断。
(define (engine-apply! e effect)
  (match effect
    [(edit-effect vid op)
     (define v (need-view e vid))
     (engine-clear-face-layers! e (view-buffer v))
     (buffer-edit! (view-buffer v) v op)]
    [(insert-text-effect vid text)
     (define v (need-view e vid))
     (engine-clear-face-layers! e (view-buffer v))
     (buffer-edit! (view-buffer v) v (op-type text))]
    [(set-text-effect vid text)
     (define v (need-view e vid))
     (engine-clear-face-layers! e (view-buffer v))
     (define n (string-length text))
     (buffer-set-document! (view-buffer v) text)
     (view-scroll-to-line! v 0)
     (view-scroll-to-column! v 0)
     (view-set-selections! v (selections-one (caret (point 0 n))) #:ensure? #f)]
    [(set-input-prompt-effect vid prompt)
     (define v (need-view e vid))
     (define b (view-buffer v))
     (define n (string-length prompt))
     (buffer-set-document! b prompt)
     (buffer-readonly-range! b (range-of (point 0 0) (point 0 n)) #t)
     (view-scroll-to-line! v 0)
     (view-scroll-to-column! v 0)
     (view-set-selections! v (selections-one (caret (point 0 n))) #:ensure? #f)]
    [(select-effect vid sels)
     (view-set-selections! (need-view e vid) sels)]
    [(scroll-effect vid delta)
     (view-scroll! (need-view e vid) delta)]
    [(nav-effect vid dir)
     (apply-nav! (need-view e vid) dir)]
    [(undo-effect vid)
     (define v (need-view e vid))
     (engine-clear-face-layers! e (view-buffer v))
     (buffer-undo! (view-buffer v))]
    [(redo-effect vid)
     (define v (need-view e vid))
     (engine-clear-face-layers! e (view-buffer v))
     (buffer-redo! (view-buffer v))]
    [_ (error 'engine-apply! "不是引擎 effect：~a" effect)])
  (void))

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
