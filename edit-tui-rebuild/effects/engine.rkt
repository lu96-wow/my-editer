#lang racket

;;; effects/engine.rkt —— core buffer / view 的唯一拥有者（不纯：可变引擎）
;;;
;;; 方案 B 的边界：
;;;   · State 只存 doc-id / view-id 与元数据；
;;;   · engine 持有真正的 core buffer / view 句柄；
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
         ;; 只读查询接口（ctx.engine）
         (struct-out engine-view)
         make-engine-view
         engine-view-doc-text engine-view-doc-name engine-view-doc-version
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
         "../base/effect.rkt")

;;; ════════════════════════ 引擎 ════════════════════════

(struct engine (docs views) #:mutable #:transparent)
;; docs  : (hash/c doc-id buffer)
;; views : (hash/c view-id view)

(define (make-engine)
  (engine (hash) (hash)))

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
  (or (edit-effect? e) (insert-text-effect? e) (select-effect? e)
      (scroll-effect? e) (nav-effect? e) (undo-effect? e) (redo-effect? e)))

;; 应用一个“只改 core”的 effect。返回 void。
;; 不是引擎 effect（open/close/io/…）-> error，调用方应先用 engine-effect? 判断。
(define (engine-apply! e effect)
  (match effect
    [(edit-effect vid op)
     (define v (need-view e vid))
     (buffer-edit! (view-buffer v) v op)]
    [(insert-text-effect vid text)
     (define v (need-view e vid))
     (buffer-edit! (view-buffer v) v (op-type text))]
    [(select-effect vid sels)
     (view-set-selections! (need-view e vid) sels)]
    [(scroll-effect vid delta)
     (view-scroll! (need-view e vid) delta)]
    [(nav-effect vid dir)
     (apply-nav! (need-view e vid) dir)]
    [(undo-effect vid)
     (buffer-undo! (view-buffer (need-view e vid)))]
    [(redo-effect vid)
     (buffer-redo! (view-buffer (need-view e vid)))]
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

(struct open-doc-spec (name text mode path line-numbers?) #:transparent)

(define (make-open-doc-spec name text
                            #:mode [mode 'text]
                            #:path [path #f]
                            #:line-numbers? [line-numbers? #f])
  (open-doc-spec name text mode path line-numbers?))

;; 便捷构造 effect：k : (state doc-id view-id -> transition)。
(define (open-doc-effect* spec k)
  (open-doc-effect spec k))
