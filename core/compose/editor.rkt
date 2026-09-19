#lang racket

(require "../text/point.rkt" "../text/content.rkt" "../text/buffer.rkt" "../text/edit.rkt"
         "../text/patch.rkt"
         "../view/window.rkt" "../view/view.rkt" "../view/screen.rkt" "../view/project.rkt"
         "../tool/history.rkt" rackunit)

;;; core/compose/editor.rkt —— editor 状态 + 无策略原语 + 中性查询
;;;
;;; 本层只回答「是什么」和「怎么把状态写对」，**不作任何显示决策**。
;;; 三类东西分清：
;;;
;;;   原语（无策略）
;;;     editor-swap-buffer   换某 buffer 的 buffer 值；entries + 同 buffer view 的
;;;                          window.buffer 一起换。**不**映射光标、不滚屏、不 ensure。
;;;     editor-apply-desc    内容变更唯一漏斗：算新 buffer → editor-swap-buffer。
;;;     editor-put-view      换一个 view 的 window；不碰别的 view。
;;;     editor-put-history   换账本；editor-record-history 记一步。
;;;
;;;   中性面（查询 / 解析 / 标注 / 投影 / 生命周期）
;;;     这些对「用户 / 程序」无差别，放这里。
;;;
;;;   显示语义（内容变更后视图怎么反应）
;;;     不在本层：reaction.rkt（none / map / leader）。
;;;   程序面：program.rkt；用户面：command.rkt。
;;;
;;; 不变量：任一 view 的 (window-buffer v) 必 eq? 于其 buffer-id 对应 entry 的 buffer。
;;; 「换 buffer 引用」只此一处。

(provide
 (struct-out editor)
 (struct-out change-report)
 ;; 只读投影
 buffer-entry-id buffer-entry-name
 view-id view-buffer-id view-sync view-window
 editor-view-ref
 ;; 构造 / 生命周期
 editor-open
 editor-open-buffer
 editor-close-buffer
 editor-add-view
 editor-close-view
 ;; 查询
 editor-buffer-count
 editor-view-count
 editor-buffers
 editor-views
 editor-focus
 editor-focus-view
 editor-focused-view
 editor-focused-buffer-id
 editor-focus-buffer
 editor-buffer
 editor-buffer-name
 editor-view-buffer-id
 editor-history
 ;; 视图结构变换（无策略；不改文本）
 editor-set-view-sync
 editor-set-view-buffer
 ;; 原语（无策略）
 editor-swap-buffer
 editor-apply-desc
 editor-put-view
 editor-record-history
 editor-put-history
 ;; 光标 / 尺寸 / 映射（只读）
 editor-point
 editor-view-point
 editor-height
 editor-width
 editor-view-height
 editor-view-width
 editor-top-line
 editor-view-top-line
 editor-point->screen
 editor-view-point->screen
 editor-screen->point
 editor-view-screen->point
 ;; 投影
 editor->screen
 editor-view->screen
 ;; 屏幕工具（别名）
 editor-make-screen
 editor-screen->text
 editor-screen-diff-rows
 editor-screen-compose
 ;; 文本 / 解析（按 buffer-id）
 editor-buffer->string
 editor-buffer->lines
 editor-buffer-line-count
 editor-buffer-line-ref
 editor-buffer-line-length
 editor-buffer-clamp-point
 editor-buffer-point->offset
 editor-buffer-offset->point
 editor-buffer-range-text
 ;; 标注（按 buffer-id；不碰光标）
 editor-get-property
 editor-read-only-at?
 editor-restrict-runs
 editor-buffer-modified?
 editor-put-property
 editor-remove-property
 editor-put-properties-many
 editor-put-restrict
 editor-apply-patches
 ;; 账本查询
 editor-can-undo?
 editor-can-redo?
 editor-undo-depth
 editor-redo-depth)

;;; ---------- 数据 ----------

(struct buffer-entry (id name buffer history) #:transparent)

;; 一次命令影响到的行区间（新坐标系）；命令返回 #f 表示什么都没发生
(struct change-report (first-line last-line) #:transparent)

(struct view (id buffer-id window sync) #:transparent)
;; sync : 'free | 'follow   —— 显示语义的策略槽，由 reaction 读取

(struct editor (buffers views focus next-buffer next-view) #:transparent)
;; buffers   : (listof buffer-entry)   顺序稳定
;; views     : (listof view)           顺序稳定
;; focus     : (or/c #f view-id)
;; next-*    : nat                     下一个可用 id

;;; ---------- 查找 ----------

(define (editor-buffer-entry ed bid)
  (or (for/first ([e (in-list (editor-buffers ed))] #:when (= bid (buffer-entry-id e))) e)
      (error 'editor "没有这个 buffer id: ~a" bid)))

(define (editor-view-ref ed vid)
  (or (for/first ([v (in-list (editor-views ed))] #:when (= vid (view-id v))) v)
      (error 'editor "没有这个 view id: ~a" vid)))

(define (check-sync who s)
  (unless (memq s '(free follow))
    (error who "sync 必须是 'free 或 'follow，得到 ~a" s)))

(define (editor-focused-view ed)
  (define f (editor-focus ed))
  (unless f (error 'editor "当前没有焦点视图"))
  (editor-view-ref ed f))

;;; ---------- 构造 / 生命周期 ----------

(define (editor-open text [height 24] [width 80] #:name [name "*scratch*"])
  (define b (buffer-open text))
  (define entry (buffer-entry 0 name b (make-history)))
  (editor (list entry) (list (view 0 0 (window-open b height width) 'free)) 0 1 1))

;; 新增一个 buffer + 一个视图。#:focus? 控制是否把焦点交给新视图（默认是）。
;; 返回 (values editor buffer-id)。
(define (editor-open-buffer ed name text [height 24] [width 80] #:focus? [focus? #t])
  (define bid (editor-next-buffer ed))
  (define entry (buffer-entry bid name (buffer-open text) (make-history)))
  (define ed1 (struct-copy editor ed
               [buffers (append (editor-buffers ed) (list entry))]
               [next-buffer (add1 bid)]))
  (define-values (ed2 _vid) (editor-add-view ed1 bid height width #:focus? focus?))
  (values ed2 bid))

;; 新增一个视图。#:focus? 控制是否 focus 它（默认是）。返回 (values editor view-id)。
(define (editor-add-view ed bid [height 24] [width 80] [p (point 0 0)]
                         #:sync [sync 'free] #:focus? [focus? #t])
  (check-sync 'editor-add-view sync)
  (define entry (editor-buffer-entry ed bid))
  (define vid (editor-next-view ed))
  (define w (window-clamp-view
             (window-set-point (window-open (buffer-entry-buffer entry) height width) p)))
  (values (struct-copy editor ed
            [views (append (editor-views ed) (list (view vid bid w sync)))]
            [focus (if focus? vid (editor-focus ed))]
            [next-view (add1 vid)])
          vid))

(define (editor-close-view ed vid)
  (define vs (filter (lambda (v) (not (= (view-id v) vid))) (editor-views ed)))
  (define focus (if (= (editor-focus ed) vid)
                    (if (null? vs) #f (view-id (car vs)))
                    (editor-focus ed)))
  (struct-copy editor ed [views vs] [focus focus]))

(define (editor-close-buffer ed bid)
  (define vs (filter (lambda (v) (not (= (view-buffer-id v) bid))) (editor-views ed)))
  (define bs (filter (lambda (e) (not (= (buffer-entry-id e) bid))) (editor-buffers ed)))
  (define focus
    (cond [(null? vs) #f]
          [(for/or ([v (in-list vs)]) (= (view-id v) (editor-focus ed))) (editor-focus ed)]
          [else (view-id (car vs))]))
  (struct-copy editor ed [buffers bs] [views vs] [focus focus]))

;;; ---------- 查询 ----------

(define (editor-buffer-count ed) (length (editor-buffers ed)))
(define (editor-view-count ed) (length (editor-views ed)))
(define (editor-focused-buffer-id ed) (view-buffer-id (editor-focused-view ed)))
(define (editor-buffer ed bid) (buffer-entry-buffer (editor-buffer-entry ed bid)))
(define (editor-buffer-name ed bid) (buffer-entry-name (editor-buffer-entry ed bid)))
(define (editor-view-buffer-id ed vid) (view-buffer-id (editor-view-ref ed vid)))
(define (editor-history ed bid) (buffer-entry-history (editor-buffer-entry ed bid)))

(define (editor-focus-view ed vid)
  (editor-view-ref ed vid)                 ; 校验存在
  (struct-copy editor ed [focus vid]))

(define (editor-focus-buffer ed bid)
  (define v (for/first ([v (in-list (editor-views ed))] #:when (= bid (view-buffer-id v))) v))
  (if v (struct-copy editor ed [focus (view-id v)]) ed))

;;; ---------- 视图结构变换（无策略） ----------

(define (editor-set-view-sync ed vid sync)
  (check-sync 'editor-set-view-sync sync)
  (struct-copy editor ed
    [views (for/list ([v (in-list (editor-views ed))])
             (if (= (view-id v) vid) (struct-copy view v [sync sync]) v))]))

;; 把某个 view 切到另一个 buffer（换属主；不触发任何同步）
(define (editor-set-view-buffer ed vid bid)
  (define entry (editor-buffer-entry ed bid))
  (struct-copy editor ed
    [views (for/list ([v (in-list (editor-views ed))])
             (if (= (view-id v) vid)
                 (struct-copy view v
                   [buffer-id bid]
                   [window (window-clamp-view
                            (window-set-buffer (view-window v) (buffer-entry-buffer entry)))])
                 v))]))

;;; ---------- 原语（无策略） ----------

;; 换某 buffer 的 buffer 值：entries + 同 buffer view 的 window.buffer 一起换。
;; **不**动光标、不滚屏、不 ensure（即使文本变了，光标也不映射）。
;; 这是「none 显示语义」的写入部分；annotation 也走它（文本没变，光标无需处理）。
(define (editor-swap-buffer ed bid b*)
  (struct-copy editor ed
    [buffers (for/list ([e (in-list (editor-buffers ed))])
               (if (= (buffer-entry-id e) bid) (struct-copy buffer-entry e [buffer b*]) e))]
    [views (for/list ([v (in-list (editor-views ed))])
             (if (= (view-buffer-id v) bid)
                 (struct-copy view v
                   [window (struct-copy window (view-window v) [buffer b*])])
                 v))]))

;; 内容变更唯一漏斗：把 desc 施加到 bid 的 buffer，再换引用。
;; 返回 (values editor 生效desc/#f)。**不做**任何显示决策（不映射光标）。
(define (editor-apply-desc ed bid d [guard? #t])
  (define b0 (editor-buffer ed bid))
  (define-values (b* d*) (if guard? (buffer-apply-edit b0 d) (buffer-apply-edit-trusted b0 d)))
  (if (not d*)
      (values ed #f)
      (values (editor-swap-buffer ed bid b*) d*)))

;; 换一个 view 的 window（夹紧视口）；不碰别的 view。
(define (editor-put-view ed vid w)
  (editor-view-ref ed vid)                 ; 校验存在
  (struct-copy editor ed
    [views (for/list ([v (in-list (editor-views ed))])
             (if (= (view-id v) vid)
                 (struct-copy view v [window (window-clamp-view w)])
                 v))]))

(define (editor-record-history ed bid ch)
  (define entry (editor-buffer-entry ed bid))
  (define entry* (struct-copy buffer-entry entry
                  [history (history-record (buffer-entry-history entry) ch)]))
  (struct-copy editor ed
    [buffers (for/list ([e (in-list (editor-buffers ed))])
               (if (= (buffer-entry-id e) bid) entry* e))]))

(define (editor-put-history ed bid h)
  (struct-copy editor ed
    [buffers (for/list ([e (in-list (editor-buffers ed))])
               (if (= (buffer-entry-id e) bid) (struct-copy buffer-entry e [history h]) e))]))

;;; ---------- 光标 / 尺寸 / 映射（只读） ----------

(define (editor-point ed) (window-point (view-window (editor-focused-view ed))))
(define (editor-view-point ed vid) (window-point (view-window (editor-view-ref ed vid))))
(define (editor-height ed) (window-height (view-window (editor-focused-view ed))))
(define (editor-width ed) (window-width (view-window (editor-focused-view ed))))
(define (editor-view-height ed vid) (window-height (view-window (editor-view-ref ed vid))))
(define (editor-view-width ed vid) (window-width (view-window (editor-view-ref ed vid))))
(define (editor-top-line ed) (window-top-line (view-window (editor-focused-view ed))))
(define (editor-view-top-line ed vid) (window-top-line (view-window (editor-view-ref ed vid))))

(define (editor-point->screen ed) (window-point->screen (view-window (editor-focused-view ed))))
(define (editor-view-point->screen ed vid)
  (window-point->screen (view-window (editor-view-ref ed vid))))
(define (editor-screen->point ed row col)
  (window-screen->point (view-window (editor-focused-view ed)) row col))
(define (editor-view-screen->point ed vid row col)
  (window-screen->point (view-window (editor-view-ref ed vid)) row col))

;;; ---------- 投影 ----------

(define (editor-view->screen ed vid)
  (window->screen (view-window (editor-view-ref ed vid))))
(define (editor->screen ed)
  (editor-view->screen ed (editor-focus ed)))

(define editor-make-screen make-screen)
(define editor-screen->text screen->text)
(define editor-screen-diff-rows screen-diff-rows)
(define editor-screen-compose screen-compose)

;;; ---------- 文本 / 标记（按 buffer-id） ----------

(define (editor-buffer->string ed bid) (buffer->string (editor-buffer ed bid)))
(define (editor-buffer->lines ed bid) (buffer->lines (editor-buffer ed bid)))
(define (editor-buffer-line-count ed bid) (buffer-line-count (editor-buffer ed bid)))
(define (editor-buffer-line-ref ed bid i) (buffer-line-ref (editor-buffer ed bid) i))
(define (editor-buffer-line-length ed bid i) (buffer-line-length (editor-buffer ed bid) i))
;; 位置解析：只依赖 bid 指向的 buffer，与任何 view/光标无关。插件入口。
(define (editor-buffer-clamp-point ed bid p) (buffer-clamp-point (editor-buffer ed bid) p))
(define (editor-buffer-point->offset ed bid p) (buffer-point->offset (editor-buffer ed bid) p))
(define (editor-buffer-offset->point ed bid off) (buffer-offset->point (editor-buffer ed bid) off))
(define (editor-buffer-range-text ed bid s e) (buffer-range-text (editor-buffer ed bid) s e))
(define (editor-get-property ed bid p key) (buffer-get-property (editor-buffer ed bid) p key))
(define (editor-read-only-at? ed bid p) (buffer-read-only-at? (editor-buffer ed bid) p))
(define (editor-restrict-runs ed bid line) (buffer-restrict-runs (editor-buffer ed bid) line))
(define (editor-buffer-modified? ed bid) (buffer-modified? (editor-buffer ed bid)))

;; 标注写入：只换 buffer 值（editor-swap-buffer），文本不变 → 不需要动光标。
(define (editor-update-buffer ed bid f)
  (editor-swap-buffer ed bid (f (editor-buffer ed bid))))

(define (editor-put-property ed bid start end key val)
  (editor-update-buffer ed bid (lambda (b) (buffer-put-property b start end key val))))
(define (editor-remove-property ed bid start end key)
  (editor-update-buffer ed bid (lambda (b) (buffer-remove-property b start end key))))
(define (editor-put-properties-many ed bid segs)
  (editor-update-buffer ed bid (lambda (b) (buffer-put-properties-many b segs))))
(define (editor-put-restrict ed bid start end rs)
  (editor-update-buffer ed bid (lambda (b) (buffer-put-restrict b start end rs))))
(define (editor-apply-patches ed bid patches)
  (editor-update-buffer ed bid (lambda (b) (buffer-apply-patches b patches))))

;;; ---------- 账本查询 ----------

(define (editor-can-undo? ed bid) (history-can-undo? (editor-history ed bid)))
(define (editor-can-redo? ed bid) (history-can-redo? (editor-history ed bid)))
(define (editor-undo-depth ed bid) (history-undo-depth (editor-history ed bid)))
(define (editor-redo-depth ed bid) (history-redo-depth (editor-history ed bid)))

;;; ---------- 测试：只测原语（显示语义在 reaction，命令在 program/command） ----------

(module+ test
  ;; 原语：内容变更不动光标、不滚屏
  (define e0 (editor-open "l0\nl1\nl2\nl3\nl4\nl5" 3 10))
  (define e1 (let-values ([(e _) (editor-apply-desc e0 0 (edit-desc (point 0 0) (point 0 0) "XY"))]) e))
  (check-equal? (editor-buffer->string e1 0) "XYl0\nl1\nl2\nl3\nl4\nl5")
  (check-equal? (editor-point e1) (point 0 0))          ; 光标字面不动
  (check-equal? (editor-top-line e1) 0)
  (check-eq? (editor-buffer e1 0) (window-buffer (view-window (editor-view-ref e1 0))))

  ;; 被守卫拒绝 → 原样、desc #f
  (define er (editor-put-restrict (editor-open "abcd") 0 (point 0 0) (point 0 4) (restrict #t)))
  (define-values (er* dr) (editor-apply-desc er 0 (edit-desc (point 0 1) (point 0 1) "X")))
  (check-eq? er* er)
  (check-false dr)

  ;; 标注写入：换引用、不动光标
  (define a0 (editor-open "hello"))
  (define a1 (editor-put-properties-many a0 0 (list (list (point 0 0) (point 0 5) 'face 'bold))))
  (check-equal? (editor-get-property a1 0 (point 0 2) 'face) 'bold)
  (check-equal? (editor-buffer->string a1 0) "hello")

  ;; #:focus? #f：后台开 buffer 不抢焦点
  (define f0 (editor-open "AAA"))
  (define-values (f1 _bid) (editor-open-buffer f0 "b" "BBB" #:focus? #f))
  (check-equal? (editor-focused-buffer-id f1) 0)

  (displayln "editor.rkt: core tests passed"))
