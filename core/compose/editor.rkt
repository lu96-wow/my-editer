#lang racket

(require "../text/point.rkt" "../text/buffer.rkt" "../text/edit.rkt"
         "../view/window.rkt" "../view/view.rkt" "../view/document.rkt"
         "../view/screen.rkt" "../view/project.rkt"
         "../tool/history.rkt" rackunit)

;;; core/compose/editor.rkt —— 统一的编辑平台：editor
;;;
;;; editor = document + 账本 + 活动视图。**这是使用者唯一碰的有状态对象**，
;;; 所有日常操作都在 editor-* 上，不需要在 editor 和 document 之间来回搬：
;;;
;;;   构造   editor-open / editor-of-document
;;;   视图   editor-window / editor-add-view / editor-update-view / editor-set-view-size …
;;;   投影   editor->screen / editor-view->screen
;;;   读     editor->string / editor-line-ref / editor-range-text / editor-get-property …
;;;   标注   editor-put-property / editor-put-restrict / editor-apply-patches …（不改文本、不动账本）
;;;   编辑   editor-edit / editor-undo / editor-redo   → (values editor (or/c #f change-report))
;;;   账本   editor-can-undo? / editor-undo-depth …
;;;
;;; document 是**机制**（buffer + 多视图 + rebase），由 editor 内部持有；
;;; 需要下探时才用逃生门 editor-document（并配合 core/api.rkt 的 document-*）。

(provide
 (struct-out editor)
 (struct-out change-report)
 ;; 构造
 editor-open
 editor-of-document
 ;; 视图
 editor-window
 editor-view-window
 editor-view-count
 editor-add-view
 editor-set-active
 editor-update-view
 editor-update-active
 editor-set-view-size
 editor-set-mode
 editor-view-sync
 editor-set-view-sync
 ;; 光标 / 尺寸
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
 ;; 光标 / 鼠标映射
 editor-point->screen
 editor-view-point->screen
 editor-screen->point
 editor-view-screen->point
 ;; 导航（活动视图）
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
 ;; 屏幕工具（别名：与同名原子是同一个过程对象）
 editor-make-screen
 editor-screen->text
 editor-screen-diff-rows
 editor-screen-compose
 ;; 读
 editor->string
 editor->lines
 editor-line-count
 editor-line-ref
 editor-range-text
 editor-get-property
 editor-read-only-at?
 editor-restrict-runs
 editor-buffer
 editor-modified?
 ;; 标注
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

;;; ---------- 状态 ----------

;; document : document   一个 buffer + 多个视图（机制）
;; history  : history    撤销/重放账本（工具层）
;; active   : nat        当前编辑的视图下标
(struct editor (document history active) #:transparent)

;; 一次命令影响到的行区间（**新坐标系**）。命令返回 #f 表示什么都没发生。
(struct change-report (first-line last-line) #:transparent)

;;; ---------- 构造 ----------

(define (editor-open text [height 24] [width 80])
  (define-values (doc _u1) (document-add-view (document-open text) height width))
  (editor doc (make-history) 0))

(define (editor-of-document doc [active 0])
  (editor doc (make-history) active))

;; 内部：换 document（保留账本与活动视图）
(define (with-document ed f)
  (struct-copy editor ed [document (f (editor-document ed))]))

;;; ---------- 视图 ----------

;; 活动视图的 window（渲染/查询用）
(define (editor-window ed)
  (document-window (editor-document ed) (editor-active ed)))

(define (editor-view-window ed i)
  (document-window (editor-document ed) i))

(define (editor-view-count ed)
  (document-view-count (editor-document ed)))

(define (editor-add-view ed [height 24] [width 80] [p (point 0 0)] #:sync [sync 'free])
  (define-values (doc i) (document-add-view (editor-document ed) height width p #:sync sync))
  (values (struct-copy editor ed [document doc]) i))

(define (editor-set-active ed i)
  (struct-copy editor ed [active i]))

(define (editor-update-view ed i f)
  (with-document ed (lambda (doc) (document-update-view doc i f))))

;; 更新**活动视图**（导航/滚动/尺寸），并同步 follow 视图
(define (editor-update-active ed f)
  (editor-update-view ed (editor-active ed) f))

(define (editor-set-view-size ed i height width)
  (with-document ed (lambda (doc) (document-set-view-size doc i height width))))

(define (editor-view-sync ed i) (document-view-sync (editor-document ed) i))

(define (editor-set-view-sync ed i sync)
  (with-document ed (lambda (doc) (document-set-view-sync doc i sync))))

(define (editor-set-mode ed mode)
  (editor-update-active ed (lambda (w) (window-set-mode w mode))))

;;; ---------- 光标 / 尺寸 ----------

(define (editor-point ed) (window-point (editor-window ed)))
(define (editor-view-point ed i) (window-point (editor-view-window ed i)))
(define (editor-height ed) (window-height (editor-window ed)))
(define (editor-width ed) (window-width (editor-window ed)))
(define (editor-view-height ed i) (window-height (editor-view-window ed i)))
(define (editor-view-width ed i) (window-width (editor-view-window ed i)))
(define (editor-top-line ed) (window-top-line (editor-window ed)))
(define (editor-view-top-line ed i) (window-top-line (editor-view-window ed i)))

(define (editor-set-point ed p)
  (editor-update-active ed (lambda (w) (window-set-point w p))))
(define (editor-view-set-point ed i p)
  (editor-update-view ed i (lambda (w) (window-set-point w p))))

;;; ---------- 光标 / 鼠标映射 ----------

(define (editor-point->screen ed) (window-point->screen (editor-window ed)))
(define (editor-view-point->screen ed i) (window-point->screen (editor-view-window ed i)))
(define (editor-screen->point ed row col) (window-screen->point (editor-window ed) row col))
(define (editor-view-screen->point ed i row col)
  (window-screen->point (editor-view-window ed i) row col))

;;; ---------- 导航（活动视图；移动后 ensure 光标可见）----------

(define (editor-move ed f)
  (editor-update-active ed (lambda (w) (window-ensure-point (f w)))))

(define (editor-left ed)  (editor-move ed window-left))
(define (editor-right ed) (editor-move ed window-right))
(define (editor-up ed)    (editor-move ed window-up))
(define (editor-down ed)  (editor-move ed window-down))
(define (editor-home ed)  (editor-move ed window-home))
(define (editor-end ed)   (editor-move ed window-end))
(define (editor-goto ed line col) (editor-move ed (lambda (w) (window-goto w line col))))

;; 显式滚视口（不 ensure；按视觉行，clip/wrap 都行）
(define (editor-scroll ed delta)
  (editor-update-active ed (lambda (w) (window-scroll-visual w delta))))

;;; ---------- 投影（window → screen）----------

;; 活动视图投影成 screen（= window->screen (editor-window ed)）
(define (editor->screen ed)
  (window->screen (editor-window ed)))

;; 第 i 个视图投影成 screen（多窗格布局用）
(define (editor-view->screen ed i)
  (window->screen (editor-view-window ed i)))

;; 拼屏：多窗格用 editor-view->screen 拼成整屏。与 screen-compose 同一个过程对象，
;; 提供 editor-* 前缀只是为了让使用者的平台面统一。
(define editor-screen-compose screen-compose)
(define editor-make-screen make-screen)
(define editor-screen->text screen->text)
(define editor-screen-diff-rows screen-diff-rows)

;;; ---------- 读 ----------

(define (editor->string ed) (document->string (editor-document ed)))
(define (editor->lines ed) (document->lines (editor-document ed)))
(define (editor-line-count ed) (document-line-count (editor-document ed)))
(define (editor-line-ref ed i) (document-line-ref (editor-document ed) i))
(define (editor-range-text ed start end) (document-range-text (editor-document ed) start end))
(define (editor-get-property ed line col key) (document-get-property (editor-document ed) line col key))
(define (editor-read-only-at? ed line col) (document-read-only-at? (editor-document ed) line col))
(define (editor-restrict-runs ed line) (document-restrict-runs (editor-document ed) line))
;; 逃生门：真 buffer（标注/属性等的底层结构）；大多数时候用不到
(define (editor-buffer ed) (document-buffer (editor-document ed)))
(define (editor-modified? ed) (buffer-modified? (editor-buffer ed)))

;;; ---------- 标注（不改文本、不动账本）----------

(define (editor-put-property ed line start end key val)
  (with-document ed (lambda (doc) (document-put-property doc line start end key val))))
(define (editor-remove-property ed line start end key)
  (with-document ed (lambda (doc) (document-remove-property doc line start end key))))
(define (editor-put-properties-many ed segs)
  (with-document ed (lambda (doc) (document-put-properties-many doc segs))))
(define (editor-put-restrict ed line start end rs)
  (with-document ed (lambda (doc) (document-put-restrict doc line start end rs))))
(define (editor-apply-patches ed patches)
  (with-document ed (lambda (doc) (document-apply-patches doc patches))))

;;; ---------- 编辑 ----------

;; op : buffer point → (or/c #f edit-desc)。返回 (values editor (or/c #f change-report))。
;; 逆用编辑前的 buffer 导出；入不入账本由本命令负责（editor-undo/redo 取用）。
(define (editor-edit ed op)
  (define-values (doc* ch) (document-edit (editor-document ed) (editor-active ed) op))
  (cond
    [(not ch) (values ed #f)]
    [else
     (define-values (f l) (edits-span (list (edit-change-desc ch))))
     (values (struct-copy editor ed
               [document doc*]
               [history (history-record (editor-history ed) ch)])
             (change-report f l))]))

(define (editor-undo ed)
  (define-values (st h*) (history-pop-undo (editor-history ed)))
  (cond
    [(not st) (values ed #f)]
    [else
     (define-values (f l) (edits-span (step-undo-descs st)))
     (define doc* (document-apply-descs-trusted (editor-document ed) (editor-active ed)
                                                (step-undo-descs st) (step-pre-point st)))
     (values (struct-copy editor ed [document doc*] [history h*])
             (change-report f l))]))

(define (editor-redo ed)
  (define-values (st h*) (history-pop-redo (editor-history ed)))
  (cond
    [(not st) (values ed #f)]
    [else
     (define-values (f l) (edits-span (step-replay-descs st)))
     (define doc* (document-apply-descs-trusted (editor-document ed) (editor-active ed)
                                                (step-replay-descs st)))
     (values (struct-copy editor ed [document doc*] [history h*])
             (change-report f l))]))

;;; ---------- 账本查询 ----------

(define (editor-can-undo? ed) (history-can-undo? (editor-history ed)))
(define (editor-can-redo? ed) (history-can-redo? (editor-history ed)))
(define (editor-undo-depth ed) (history-undo-depth (editor-history ed)))
(define (editor-redo-depth ed) (history-redo-depth (editor-history ed)))

;;; ---------- 测试 ----------

(module+ test
  (require "../view/screen.rkt")
  (define e0 (editor-open ""))

  ;; 读 / 编辑 / 报告
  (define-values (e1 r1) (editor-edit e0 (edit-insert-char #\a)))
  (define-values (e2 _ea) (editor-edit e1 (edit-insert-char #\b)))
  (define-values (e3 _eb) (editor-edit e2 (edit-insert-char #\c)))
  (check-equal? (editor->string e3) "abc")
  (check-equal? (change-report-first-line r1) 0)
  (check-equal? (editor-undo-depth e3) 1)          ; 三次单字符并成一步
  (check-equal? (window-point (editor-window e3)) (point 0 3))

  ;; 撤销 / 重做
  (define-values (u1 ur) (editor-undo e3))
  (check-equal? (editor->string u1) "")
  (check-equal? (window-point (editor-window u1)) (point 0 0))
  (check-equal? ur (change-report 0 0))
  (define-values (r1b _ec) (editor-redo u1))
  (check-equal? (editor->string r1b) "abc")
  (check-false (editor-can-redo? e3))
  (check-true (editor-can-undo? e3))

  ;; 空栈 / no-op
  (define-values (z1 zr) (editor-undo e0))
  (check-eq? z1 e0)
  (check-false zr)
  (define-values (z2 zr2) (editor-edit e0 (edit-backspace)))
  (check-eq? z2 e0)
  (check-false zr2)

  ;; 区间取文本
  (check-equal? (editor-range-text e3 (point 0 0) (point 0 3)) "abc")
  (define-values (m1 _ed) (editor-edit e0 (edit-insert "a\nb\nc")))
  (check-equal? (editor-range-text m1 (point 1 0) (point 2 1)) "b\nc")

  ;; 视图管理：多视图 / follow / 尺寸
  (define ed0 (editor-open "l0\nl1\nl2\nl3"))
  (define-values (ed1 i1) (editor-add-view ed0 2 10))
  (define-values (ed2 i2) (editor-add-view ed1 2 10 #:sync 'follow))
  (check-equal? (list i1 i2) (list 1 2))
  (check-equal? (editor-view-count ed2) 3)
  (check-equal? (editor-view-sync ed2 2) 'follow)
  (define ed3 (editor-update-active ed2 (lambda (w) (window-goto w 2 0))))
  (check-equal? (window-point (editor-window ed3)) (point 2 0))
  (check-equal? (window-point (editor-view-window ed3 2)) (point 2 0))   ; follow 跟上了
  (define ed4 (editor-set-view-size ed3 1 5 20))
  (check-equal? (window-height (editor-view-window ed4 1)) 5)
  (check-equal? (window-width (editor-view-window ed4 1)) 20)

  ;; 标注写回保留账本/视图
  (define ed5 (editor-put-properties-many ed2 (list (list 0 0 2 'face 'bold))))
  (check-equal? (editor-get-property ed5 0 1 'face) 'bold)
  (check-equal? (editor->string ed5) "l0\nl1\nl2\nl3")
  (check-equal? (editor-view-count ed5) 3)

  ;; 投影 / 拼屏
  (check-true (screen? (editor->screen e3)))
  (check-true (screen? (editor-view->screen ed2 0)))
  (check-eq? editor-screen-compose screen-compose)      ; 与原子是同一个过程对象

  ;; 光标 / 尺寸 / 映射
  (check-equal? (editor-point e3) (point 0 3))
  (check-equal? (editor-height e3) 24)
  (check-equal? (editor-width e3) 80)
  (check-equal? (call-with-values (lambda () (editor-point->screen e3)) list) '(0 3))
  (check-equal? (call-with-values (lambda () (editor-screen->point e3 0 1)) list) '(0 1))

  ;; 导航（活动视图）
  (define nv (editor-open "hello\nworld"))
  (check-equal? (editor-point (editor-right nv)) (point 0 1))
  (check-equal? (editor-point (editor-down (editor-right nv))) (point 1 1))
  (check-equal? (editor-point (editor-goto nv 1 5)) (point 1 5))
  (check-equal? (editor-point (editor-scroll (editor-goto nv 1 5) 0)) (point 1 5))

  ;; 屏幕工具与同名原子是同一过程对象
  (check-eq? editor-make-screen make-screen)
  (check-eq? editor-screen->text screen->text)
  (check-eq? editor-screen-diff-rows screen-diff-rows)

  (displayln "editor.rkt: all tests passed"))
