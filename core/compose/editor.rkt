#lang racket

(require "../text/point.rkt" "../text/content.rkt" "../text/buffer.rkt" "../text/edit.rkt"
         "../text/patch.rkt"
         "../view/window.rkt" "../view/view.rkt" "../view/rebase.rkt"
         "../view/screen.rkt" "../view/project.rkt"
         "../tool/history.rkt" rackunit)

;;; core/compose/editor.rkt —— 多 buffer、多视图的统一平台：editor
;;;
;;; 模型（buffer 与 window 解耦）：
;;;   buffer-entry  一个打开的 buffer：{ id, name, buffer, history }
;;;   view          一个窗口：{ id, buffer-id, window, sync }（window 指向 buffer）
;;;   editor        { buffers, views, focus }   —— 顶层，使用者只碰它
;;;
;;; 不变量：任一 view 的 (window-buffer v) 必 eq? 于其 buffer-id 对应 entry 的 buffer。
;;;
;;; ── 窗口同步契约（唯一实现在 view/rebase.rkt，调度在这里）──────────────
;;; 同步**只在同一 buffer 的 view 之间**发生；跨 buffer 无耦合。
;;;   · 编辑 / 撤销：leader（focus 的 view）光标推进到插入后 + ensure；
;;;     同 buffer 其余 view：free 映射光标，follow 复制 leader 的**最终**视口再按自己几何 ensure；
;;;     **所有**同 buffer view 都换成新 buffer 值（单一事实源）。
;;;   · 导航/滚动：被更新的 view 成为 leader，同 buffer 的 follow 镜像它。
;;;   · 只写标注：只换 buffer 值，不 rebase 光标（文本没变）。
;;;   · set-view-buffer：换属主，不触发同步。
;;; 次序硬约束：leader 必须**先 ensure 定稿**，follower 再复制（否则差一行）。

(provide
 (struct-out editor)
 (struct-out change-report)
 ;; buffer-entry / view 的只读投影（不暴露 window/buffer，避免手动解包）
 buffer-entry-id buffer-entry-name
 view-id view-buffer-id view-sync
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
 ;; 视图变换
 editor-update-view
 editor-update-focused
 editor-set-view-size
 editor-set-view-sync
 editor-set-view-buffer
 editor-set-mode
 ;; 光标 / 尺寸 / 映射
 editor-point
 editor-view-point
 editor-height
 editor-width
 editor-view-height
 editor-view-width
 editor-top-line
 editor-view-top-line
 editor-set-point
 editor-view-set-point
 editor-point->screen
 editor-view-point->screen
 editor-screen->point
 editor-view-screen->point
 ;; 导航（focused）
 editor-left
 editor-right
 editor-up
 editor-down
 editor-home
 editor-end
 editor-goto
 editor-scroll
 ;; 投影
 editor->screen
 editor-view->screen
 ;; 屏幕工具（别名）
 editor-make-screen
 editor-screen->text
 editor-screen-diff-rows
 editor-screen-compose
 ;; 文本 / 标注（按 buffer-id）
 editor-buffer->string
 editor-buffer->lines
 editor-buffer-line-count
 editor-buffer-line-ref
 editor-buffer-range-text
 editor-get-property
 editor-read-only-at?
 editor-restrict-runs
 editor-buffer-modified?
 editor-put-property
 editor-remove-property
 editor-put-properties-many
 editor-put-restrict
 editor-apply-patches
 ;; 编辑 / 撤销 / 重做
 editor-edit
 editor-undo
 editor-redo
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
;; sync : 'free | 'follow

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

;; 新增一个 buffer + 一个视图，并 focus 它。返回 (values editor buffer-id)。
(define (editor-open-buffer ed name text [height 24] [width 80])
  (define bid (editor-next-buffer ed))
  (define entry (buffer-entry bid name (buffer-open text) (make-history)))
  (define ed1 (struct-copy editor ed
               [buffers (append (editor-buffers ed) (list entry))]
               [next-buffer (add1 bid)]))
  (define-values (ed2 _vid) (editor-add-view ed1 bid height width))
  (values ed2 bid))

;; 新增一个视图（并 focus 它）。返回 (values editor view-id)。
(define (editor-add-view ed bid [height 24] [width 80] [p (point 0 0)] #:sync [sync 'free])
  (check-sync 'editor-add-view sync)
  (define entry (editor-buffer-entry ed bid))
  (define vid (editor-next-view ed))
  (define w (window-clamp-view
             (window-set-point (window-open (buffer-entry-buffer entry) height width) p)))
  (values (struct-copy editor ed
            [views (append (editor-views ed) (list (view vid bid w sync)))]
            [focus vid]
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

(define (editor-focus-view ed vid)
  (editor-view-ref ed vid)                 ; 校验存在
  (struct-copy editor ed [focus vid]))

(define (editor-focus-buffer ed bid)
  (define v (for/first ([v (in-list (editor-views ed))] #:when (= bid (view-buffer-id v))) v))
  (if v (struct-copy editor ed [focus (view-id v)]) ed))

;;; ---------- 视图变换 ----------

(define (editor-set-view-size ed vid height width)
  (editor-update-view ed vid (lambda (w) (window-set-size w height width))))

(define (editor-set-view-sync ed vid sync)
  (check-sync 'editor-set-view-sync sync)
  (struct-copy editor ed
    [views (for/list ([v (in-list (editor-views ed))])
             (if (= (view-id v) vid) (struct-copy view v [sync sync]) v))]))

(define (editor-set-mode ed mode)
  (editor-update-focused ed (lambda (w) (window-set-mode w mode))))

;; 把某个 view 切到另一个 buffer（换属主；不触发同步）
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

;;; ---------- 同步调度：一次 buffer 变更后的重基准 ----------

;; 换某 buffer 的所有 view 的 buffer 引用（只写标注时用；文本没变 → 光标不动）
(define (update-buffer-refs ed bid b*)
  (struct-copy editor ed
    [views (for/list ([v (in-list (editor-views ed))])
             (if (= (view-buffer-id v) bid)
                 (struct-copy view v [window (window-set-buffer (view-window v) b*)])
                 v))]))

;; 施加一条 desc 到 vid 所属 buffer，并 rebase **同 buffer 的所有 view**。
;; leader = vid。返回 (values editor 生效desc/#f)。
(define (apply-one ed vid d guard?)
  (define v (editor-view-ref ed vid))
  (define bid (view-buffer-id v))
  (define entry (editor-buffer-entry ed bid))
  (define b0 (buffer-entry-buffer entry))
  (define-values (b* d*) (if guard? (buffer-apply-edit b0 d) (buffer-apply-edit-trusted b0 d)))
  (cond
    [(not d*) (values ed #f)]
    [else
     ;; 1) leader 先 ensure 定稿
     (define editing
       (window-ensure-point
        (struct-copy window (view-window v) [buffer b*] [point (edit-desc-after-position d*)])))
     ;; 2) 同 buffer 的每个 view 重新基准；别的 buffer 不动
     (define views*
       (for/list ([x (in-list (editor-views ed))])
         (cond
           [(not (= (view-buffer-id x) bid)) x]
           [(= (view-id x) vid) (struct-copy view x [window (window-clamp-view editing)])]
           [else
            (define w (case (view-sync x)
                        [(free)   (rebase-free   (view-window x) b* d*)]
                        [(follow) (rebase-follow (view-window x) editing)]))
            (struct-copy view x [window (window-clamp-view w)])])))
     ;; 3) entry 的 buffer 换成新值
     (define entries*
       (for/list ([e (in-list (editor-buffers ed))])
         (if (= (buffer-entry-id e) bid) (struct-copy buffer-entry e [buffer b*]) e)))
     (values (struct-copy editor ed [buffers entries*] [views views*]) d*)]))

;;; ---------- 导航：更新一个 view，然后同 buffer 的 follow 镜像它 ----------

(define (editor-update-view ed vid f)
  (define v (editor-view-ref ed vid))
  (define bid (view-buffer-id v))
  (define w* (window-clamp-view (f (view-window v))))
  (define views*
    (for/list ([x (in-list (editor-views ed))])
      (cond
        [(= (view-id x) vid) (struct-copy view x [window w*])]
        [(and (= (view-buffer-id x) bid) (eq? (view-sync x) 'follow))
         (struct-copy view x [window (window-clamp-view (rebase-follow (view-window x) w*))])]
        [else x])))
  (struct-copy editor ed [views views*]))

(define (editor-update-focused ed f)
  (editor-update-view ed (editor-focus ed) f))

;;; ---------- 光标 / 尺寸 / 映射 ----------

(define (editor-point ed) (window-point (view-window (editor-focused-view ed))))
(define (editor-view-point ed vid) (window-point (view-window (editor-view-ref ed vid))))
(define (editor-height ed) (window-height (view-window (editor-focused-view ed))))
(define (editor-width ed) (window-width (view-window (editor-focused-view ed))))
(define (editor-view-height ed vid) (window-height (view-window (editor-view-ref ed vid))))
(define (editor-view-width ed vid) (window-width (view-window (editor-view-ref ed vid))))
(define (editor-top-line ed) (window-top-line (view-window (editor-focused-view ed))))
(define (editor-view-top-line ed vid) (window-top-line (view-window (editor-view-ref ed vid))))

(define (editor-set-point ed p) (editor-update-focused ed (lambda (w) (window-set-point w p))))
(define (editor-view-set-point ed vid p)
  (editor-update-view ed vid (lambda (w) (window-set-point w p))))

(define (editor-point->screen ed) (window-point->screen (view-window (editor-focused-view ed))))
(define (editor-view-point->screen ed vid)
  (window-point->screen (view-window (editor-view-ref ed vid))))
(define (editor-screen->point ed row col)
  (window-screen->point (view-window (editor-focused-view ed)) row col))
(define (editor-view-screen->point ed vid row col)
  (window-screen->point (view-window (editor-view-ref ed vid)) row col))

;;; ---------- 导航（focused；移动后 ensure 光标可见）----------

(define (editor-move ed f)
  (editor-update-focused ed (lambda (w) (window-ensure-point (f w)))))

(define (editor-left ed)  (editor-move ed window-left))
(define (editor-right ed) (editor-move ed window-right))
(define (editor-up ed)    (editor-move ed window-up))
(define (editor-down ed)  (editor-move ed window-down))
(define (editor-home ed)  (editor-move ed window-home))
(define (editor-end ed)   (editor-move ed window-end))
(define (editor-goto ed line col) (editor-move ed (lambda (w) (window-goto w line col))))
(define (editor-scroll ed delta)
  (editor-update-focused ed (lambda (w) (window-scroll-visual w delta))))

;;; ---------- 投影 ----------

(define (editor-view->screen ed vid)
  (window->screen (view-window (editor-view-ref ed vid))))
(define (editor->screen ed)
  (editor-view->screen ed (editor-focus ed)))

(define editor-make-screen make-screen)
(define editor-screen->text screen->text)
(define editor-screen-diff-rows screen-diff-rows)
(define editor-screen-compose screen-compose)

;;; ---------- 文本 / 标注（按 buffer-id） ----------

(define (editor-buffer->string ed bid) (buffer->string (editor-buffer ed bid)))
(define (editor-buffer->lines ed bid) (buffer->lines (editor-buffer ed bid)))
(define (editor-buffer-line-count ed bid) (buffer-line-count (editor-buffer ed bid)))
(define (editor-buffer-line-ref ed bid i) (buffer-line-ref (editor-buffer ed bid) i))
(define (editor-buffer-range-text ed bid s e) (buffer-range-text (editor-buffer ed bid) s e))
(define (editor-get-property ed bid line col key) (buffer-get-property (editor-buffer ed bid) line col key))
(define (editor-read-only-at? ed bid line col) (buffer-read-only-at? (editor-buffer ed bid) line col))
(define (editor-restrict-runs ed bid line) (buffer-restrict-runs (editor-buffer ed bid) line))
(define (editor-buffer-modified? ed bid) (buffer-modified? (editor-buffer ed bid)))

(define (editor-update-buffer ed bid f)
  (define b* (f (editor-buffer ed bid)))
  (define entries*
    (for/list ([e (in-list (editor-buffers ed))])
      (if (= (buffer-entry-id e) bid) (struct-copy buffer-entry e [buffer b*]) e)))
  (update-buffer-refs (struct-copy editor ed [buffers entries*]) bid b*))

(define (editor-put-property ed bid line start end key val)
  (editor-update-buffer ed bid (lambda (b) (buffer-put-property b line start end key val))))
(define (editor-remove-property ed bid line start end key)
  (editor-update-buffer ed bid (lambda (b) (buffer-remove-property b line start end key))))
(define (editor-put-properties-many ed bid segs)
  (editor-update-buffer ed bid (lambda (b) (buffer-put-properties-many b segs))))
(define (editor-put-restrict ed bid line start end rs)
  (editor-update-buffer ed bid (lambda (b) (buffer-put-restrict b line start end rs))))
(define (editor-apply-patches ed bid patches)
  (editor-update-buffer ed bid (lambda (b) (buffer-apply-patches b patches))))

;;; ---------- 编辑 ----------

(define (editor-record-history ed bid ch)
  (define entry (editor-buffer-entry ed bid))
  (define entry* (struct-copy buffer-entry entry
                  [history (history-record (buffer-entry-history entry) ch)]))
  (struct-copy editor ed
    [buffers (for/list ([e (in-list (editor-buffers ed))])
               (if (= (buffer-entry-id e) bid) entry* e))]))

(define (editor-set-history ed bid h)
  (struct-copy editor ed
    [buffers (for/list ([e (in-list (editor-buffers ed))])
               (if (= (buffer-entry-id e) bid) (struct-copy buffer-entry e [history h]) e))]))

;; 编辑 focus 的 view 所指 buffer。返回 (values editor (or/c #f change-report))。
(define (editor-edit ed op)
  (define fv (editor-focused-view ed))
  (define vid (view-id fv))
  (define bid (view-buffer-id fv))
  (define b0 (editor-buffer ed bid))
  (define p0 (window-point (view-window fv)))
  (define d (op b0 p0))
  (cond
    [(not d) (values ed #f)]
    [else
     (define-values (ed* d*) (apply-one ed vid d #t))
     (cond
       [(not d*) (values ed #f)]
       [else
        (define ch (edit-change d* (buffer-edit-desc-inverse b0 d*) p0))
        (define-values (f l) (edits-span (list d*)))
        (values (editor-record-history ed* bid ch) (change-report f l))])]))

(define (editor-undo ed)
  (define fv (editor-focused-view ed))
  (define vid (view-id fv))
  (define bid (view-buffer-id fv))
  (define entry (editor-buffer-entry ed bid))
  (define-values (st h*) (history-pop-undo (buffer-entry-history entry)))
  (cond
    [(not st) (values ed #f)]
    [else
     (define ed* (for/fold ([e ed]) ([d (in-list (step-undo-descs st))])
                   (define-values (e* _) (apply-one e vid d #f)) e*))
     (define ed** (editor-update-view ed* vid
                    (lambda (w) (window-ensure-point (window-set-point w (step-pre-point st))))))
     (define-values (f l) (edits-span (step-undo-descs st)))
     (values (editor-set-history ed** bid h*) (change-report f l))]))

(define (editor-redo ed)
  (define fv (editor-focused-view ed))
  (define vid (view-id fv))
  (define bid (view-buffer-id fv))
  (define entry (editor-buffer-entry ed bid))
  (define-values (st h*) (history-pop-redo (buffer-entry-history entry)))
  (cond
    [(not st) (values ed #f)]
    [else
     (define ed* (for/fold ([e ed]) ([d (in-list (step-replay-descs st))])
                   (define-values (e* _) (apply-one e vid d #f)) e*))
     (define-values (f l) (edits-span (step-replay-descs st)))
     (values (editor-set-history ed* bid h*) (change-report f l))]))

;;; ---------- 账本查询 ----------

(define (editor-can-undo? ed bid) (history-can-undo? (buffer-entry-history (editor-buffer-entry ed bid))))
(define (editor-can-redo? ed bid) (history-can-redo? (buffer-entry-history (editor-buffer-entry ed bid))))
(define (editor-undo-depth ed bid) (history-undo-depth (buffer-entry-history (editor-buffer-entry ed bid))))
(define (editor-redo-depth ed bid) (history-redo-depth (buffer-entry-history (editor-buffer-entry ed bid))))

;;; ---------- 测试 ----------

(module+ test
  ;; 单 buffer 编辑闭环
  (define e0 (editor-open ""))
  (define-values (e1 r1) (editor-edit e0 (edit-insert-char #\a)))
  (define-values (e2 _u1) (editor-edit e1 (edit-insert-char #\b)))
  (define-values (e3 _u2) (editor-edit e2 (edit-insert-char #\c)))
  (check-equal? (editor-buffer->string e3 0) "abc")
  (check-equal? (change-report-first-line r1) 0)
  (check-equal? (editor-undo-depth e3 0) 1)
  (define-values (u1 _u3) (editor-undo e3))
  (check-equal? (editor-buffer->string u1 0) "")
  (check-equal? (editor-point u1) (point 0 0))
  (define-values (r1b _u4) (editor-redo u1))
  (check-equal? (editor-buffer->string r1b 0) "abc")

  ;; 多 buffer：各自独立文本 / 账本 / focus
  (define ed (editor-open "AAA"))
  (define-values (ed2 bid1) (editor-open-buffer ed "b.txt" "BBB"))
  (check-equal? (editor-buffer-count ed2) 2)
  (check-equal? (editor-buffer->string ed2 0) "AAA")
  (check-equal? (editor-buffer->string ed2 bid1) "BBB")
  (check-equal? (editor-buffer-name ed2 bid1) "b.txt")
  (check-equal? (editor-focused-buffer-id ed2) bid1)          ; open-buffer 后 focus 新 buffer
  (define-values (ed3 _u5) (editor-edit ed2 (edit-insert "x")))
  (check-equal? (editor-buffer->string ed3 bid1) "xBBB")
  (check-equal? (editor-buffer->string ed3 0) "AAA")          ; 另一个 buffer 不受影响
  (check-true (editor-can-undo? ed3 bid1))
  (check-false (editor-can-undo? ed3 0))                      ; 账本按 buffer 独立

  ;; 多视图同 buffer：free 映射、follow 镜像；编辑后都指向新 buffer 值
  (define m0 (editor-open "l0\nl1\nl2\nl3\nl4\nl5\nl6"))
  (define-values (m1 v0) (editor-add-view m0 0 3 10))         ; v0 是新 view（被 focus）
  ;; m0 的 view0 是原 view；m1 现在有两个 view。把它们摆好：
  ;; 重新聚焦原 view(0)，设 v0 为 follow
  (define m2 (editor-focus-view (editor-set-view-sync m1 v0 'follow) 0))
  (define m3 (editor-goto m2 0 0))
  ;; 编辑：v0 是 follow，应镜像 leader 的最终视口
  (define-values (m4 _u6) (editor-edit m3 (edit-insert "XY")))
  (check-equal? (editor-buffer->string m4 0) "XYl0\nl1\nl2\nl3\nl4\nl5\nl6")
  (check-equal? (editor-point m4) (point 0 2))
  (check-equal? (editor-view-point m4 v0) (point 0 2))        ; follow 光标跟上
  (check-eq? (editor-buffer m4 0) (window-buffer (view-window (editor-view-ref m4 v0))))  ; 同源

  ;; set-view-buffer：让 v0 去看另一个 buffer（在同一个 editor 里新开一个）
  (define-values (m5 bid2) (editor-open-buffer m4 "other" "OTHER"))
  (define m6 (editor-focus-view m5 v0))
  (define n1 (editor-set-view-buffer m6 v0 bid2))
  (check-equal? (editor-view-buffer-id n1 v0) bid2)
  (check-equal? (editor-buffer->string n1 0) "XYl0\nl1\nl2\nl3\nl4\nl5\nl6")

  ;; 标注写回：不改文本、不 rebase 光标、所有同 buffer view 换新 buffer 值
  (define q0 (editor-open "hello"))
  (define-values (q1 qv) (editor-add-view q0 0 3 10))
  (define q2 (editor-focus-view q1 0))
  (define q3 (editor-put-properties-many q2 0 (list (list 0 0 5 'face 'bold))))
  (check-equal? (editor-get-property q3 0 0 2 'face) 'bold)
  (check-equal? (editor-buffer->string q3 0) "hello")
  (check-eq? (editor-buffer q3 0) (window-buffer (view-window (editor-view-ref q3 0))))
  (check-eq? (editor-buffer q3 0) (window-buffer (view-window (editor-view-ref q3 qv))))

  ;; 同步契约：follow 镜像 leader 的视口；free 钉住不动；别的 buffer 完全不动
  (define g0 (editor-open (string-join (map number->string (range 30)) "\n") 5 20))
  (define-values (g1 vfree) (editor-add-view g0 0 5 20))
  (define-values (g2 vfollow) (editor-add-view g1 0 5 20 #:sync 'follow))
  (define-values (g3 other) (editor-open-buffer g2 "other" "OTHER"))   ; 另一个 buffer
  (define g4 (editor-focus-view g3 0))
  (define g5 (editor-goto g4 20 0))          ; leader 光标到第 20 行 → ensure 滚屏
  (check-equal? (editor-top-line g5) 16)     ; height 5 → top = 20-5+1
  (check-equal? (editor-view-top-line g5 vfree) 0)                       ; free：视口钉住
  (check-equal? (editor-view-top-line g5 vfollow) (editor-top-line g5))  ; follow：镜像
  (define-values (g6 _u9) (editor-edit g5 (edit-insert-char #\X)))
  (check-equal? (editor-buffer->string g6 other) "OTHER")                ; 别的 buffer 不动
  (check-equal? (editor-view-top-line g6 vfollow) (editor-view-top-line g6 0))
  (check-eq? (editor-buffer g6 0) (window-buffer (view-window (editor-view-ref g6 vfollow))))

  ;; 投影 / 映射
  (check-true (screen? (editor->screen e3)))
  (check-true (screen? (editor-view->screen e3 0)))
  (check-equal? (call-with-values (lambda () (editor-point->screen e3)) list) '(0 3))
  (check-equal? (call-with-values (lambda () (editor-screen->point e3 0 1)) list) '(0 1))
  (check-eq? editor-screen-compose screen-compose)

  (displayln "editor.rkt: all tests passed"))
