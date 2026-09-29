#lang racket

;;; ============================================================================
;;; app.rkt —— 会话状态 + 文档管理
;;; ============================================================================
;;;
;;; 整个应用只有一个不可变状态值 app。它由三块数据组成：
;;;
;;;   editor         core 的 editor（所有文档 + 视图）
;;;   panes          pane-id → pane（每个 pane 是一个文档实例）
;;;   layout         布局值（叶 = pane-id；见 layout.rkt）
;;;
;;; 外加焦点（pane-id）与窗口尺寸。
;;;
;;; ── pane 是什么 ──────────────────────────────────────────────────────────
;;; 一个 pane = 一个文档实例，行为载体是 lambda：
;;;
;;;   (pane kind vid state input pointer focusable?)
;;;
;;;     kind        'tree | 'editor | 'status（仅供壳按类别找，比如状态栏）
;;;     vid         它现在用的 core 视图 id
;;;     state       它自己的状态（app 不解释；树把 root/expanded/… 放这里）
;;;     input       app × pane-id × input → app        键盘
;;;     pointer     app × pane-id × input × 局部行 × 局部列 → app   鼠标
;;;     focusable?  能否获得焦点（状态栏为 #f）
;;;
;;; **关键：打开文件会换掉编辑格 pane 的 vid（旧视图关掉、新视图加上），
;;; 但 pane-id 不变。** 所以焦点、布局、命中、焦点循环都记 pane-id，
;;; 换视图对它们完全透明。
;;;
;;; ── 文档管理 ─────────────────────────────────────────────────────────────
;;; 打开 / 显示 / 关闭 / 保存都在这里，因为它是「中枢」的职责。它只跟
;;; vid / did / opened 打交道，不认识树、缓冲、状态栏各自的逻辑。

(require "../core/editor.rkt"
         "../core/text/document.rkt"
         "../core/text/base/point.rkt"
         "fs.rkt"
         "layout.rkt"
         racket/file)

(provide (struct-out app)
         (struct-out pane)
         app-pane app-set-pane app-pane-vid app-focus-vid app-pane-rect app-pane-height
         app-path
         app-open app-show app-close app-save)

;;; ---------- 类型 ----------

(struct pane (kind vid state input pointer focusable?) #:transparent)
;; 见文件头说明。

(struct app (editor opened panes layout focus editor-pane rows cols) #:transparent)
;; editor      : core editor
;; opened      : hash（path → did）—— 已打开的文件，用于复用与显示文件名
;; panes       : hash（pane-id → pane）
;; layout      : layout 值（叶 = pane-id）
;; focus       : pane-id —— 当前焦点
;; editor-pane : pane-id —— "打开文件"落到哪个编辑格（最后聚焦过的编辑格）
;; rows / cols : 窗口尺寸

;;; ---------- pane 存取 ----------

(define (app-pane a pid) (hash-ref (app-panes a) pid))
(define (app-set-pane a pid p) (struct-copy app a [panes (hash-set (app-panes a) pid p)]))
(define (app-pane-vid a pid) (pane-vid (app-pane a pid)))
(define (app-focus-vid a) (app-pane-vid a (app-focus a)))

;; 某个 pane 在布局里的矩形（渲染、命中、新建视图时定尺寸都用它）。
(define (app-pane-rect a pid)
  (for/first ([r (in-list (layout->rects (app-layout a) 0 0 (app-cols a) (app-rows a)))]
              #:when (= pid (lrect-id r)))
    r))

(define (rect-w-or a pid fallback)
  (if (app-pane-rect a pid) (lrect-w (app-pane-rect a pid)) fallback))
(define (rect-h-or a pid fallback)
  (if (app-pane-rect a pid) (lrect-h (app-pane-rect a pid)) fallback))

;; 某个 pane 的高度（树用它把输入行钉在最下面一行）。
(define (app-pane-height a pid)
  (if (app-pane-rect a pid) (lrect-h (app-pane-rect a pid)) (app-rows a)))

;;; ---------- 文档管理 ----------

;; 文档 id → 路径（没有 = scratch）。
(define (app-path a did)
  (for/first ([(p d) (in-hash (app-opened a))] #:when (= d did)) p))

;; 让某个编辑格 pane 显示某个文档：关掉它旧视图 → 加新视图 → 记回 pane（换 vid）。
;; **不改焦点**（打开文件不抢焦点）；只把 editor-pane 记成这个格，供后续打开复用。
(define (app-show a pid did)
  (define p (app-pane a pid))
  (define ed (editor-close-view (app-editor a) (pane-vid p)))
  (define-values (ed2 vid)
    (editor-add-view ed did (rect-w-or a pid 40) (rect-h-or a pid 10)
                     'free #f #:line-numbers? #t))
  (define a1 (app-set-pane (struct-copy app a [editor ed2]) pid
                           (struct-copy pane p [vid vid])))
  (struct-copy app a1 [editor-pane pid]))

;; 打开路径：已开就复用；否则读文件、建文档、记 opened，再显示到 editor-pane。
;; 路径不存在 / 不是普通文件 → 原样返回（不抛异常）。
(define (app-open a path)
  (define target (app-editor-pane a))
  (define existing (hash-ref (app-opened a) path #f))
  (cond
    [existing (app-show a target existing)]
    [(not (and (file-exists? path) (not (directory-exists? path)))) a]
    [else
     (define text (fs-read path))
     (define-values (ed* did)
       (editor-add-document (app-editor a) text
                            (path->string (file-name-from-path path))))
     (app-show (struct-copy app a [editor ed*]
                            [opened (hash-set (app-opened a) path did)])
               target did)]))

;; 关闭文档：若正被某个编辑格显示，就在**同一个 pane** 里换回一个空 scratch。
(define (app-close a did)
  (define ed (app-editor a))
  (define pid (for/first ([(id p) (in-hash (app-panes a))]
                          #:when (and (eq? (pane-kind p) 'editor)
                                      (= did (editor-view-document-id ed (pane-vid p)))))
                id))
  (define ed1 (if pid (editor-close-view ed (pane-vid (app-pane a pid))) ed))
  (define ed2 (editor-close-document ed1 did))
  (define a1 (struct-copy app a [editor ed2]
               [opened (for/hash ([(p d) (in-hash (app-opened a))] #:unless (= d did))
                         (values p d))]))
  (cond
    [pid
     (define-values (ed3 _did vid)
       (editor-add-document-view ed2 "" (rect-w-or a pid 40) (rect-h-or a pid 10)
                                 "*scratch*" #:line-numbers? #t))
     (define a2 (struct-copy app a1 [editor ed3]))
     (app-set-pane a2 pid (struct-copy pane (app-pane a2 pid) [vid vid]))]
    [else a1]))

;; 保存某个编辑格当前文档（有路径才写）。
(define (app-save a pid)
  (define ed (app-editor a))
  (define vid (app-pane-vid a pid))
  (define path (app-path a (editor-view-document-id ed vid)))
  (cond
    [path (display-to-file (editor-view-string ed vid) path #:exists 'replace) a]
    [else a]))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit "input.rkt")

  (define d (make-temporary-file "rbapp-~a" 'directory))
  (define f (build-path d "a.txt"))
  (display-to-file "hello\nworld\n" f #:exists 'replace)

  ;; 三个 pane：0 树 / 1 编辑格 / 2 状态栏
  (define ed0 (editor-open "" 10 5 #:line-numbers? #t))
  (define-values (ed1 _tdid tvid) (editor-add-document-view ed0 "" 10 4 "*tree*" #:line-numbers? #f))
  (define-values (ed2 _sdid svid) (editor-add-document-view ed1 "" 40 1 "*status*" #:line-numbers? #f))
  (define panes (hash 0 (pane 'tree tvid #f #f #f #t)
                      1 (pane 'editor 0 #f #f #f #t)
                      2 (pane 'status svid #f #f #f #f)))
  (define a (app ed2 (hash) panes (vsplit-bottom 1 (hsplit-left 30 (lpane 0) (lpane 1) 1) (lpane 2))
                 0 1 5 40))

  ;; 打开 → 建文档 + 显示 + 焦点到编辑格
  (define a1 (app-open a f))
  (check-true (hash-has-key? (app-opened a1) f))
  (check-equal? (editor-view-string (app-editor a1) (app-pane-vid a1 1)) "hello\nworld\n")
  (check-equal? (app-focus a1) 0)          ; 打开不抢焦点（仍是原来的 0）
  ;; 换视图后 pane-id 不变
  (check-true (hash-has-key? (app-panes a1) 1))

  ;; 保存
  (define edv (app-pane-vid a1 1))
  (define-values (ed* _ch) (editor-view-insert (app-editor a1) edv "X"))
  (define a3 (app-save (struct-copy app a1 [editor ed*]) 1))
  (check-equal? (file->string f) "Xhello\nworld\n")

  ;; 关闭 → 同 pane 换 scratch
  (define a4 (app-close a3 (hash-ref (app-opened a3) f)))
  (check-false (hash-has-key? (app-opened a4) f))
  (check-equal? (editor-view-string (app-editor a4) (app-pane-vid a4 1)) "")

  ;; 打开不存在的路径 → 原样返回（不抛异常、不退出）
  (define a5 (app-open a4 (build-path d "nope.txt")))
  (check-equal? (length (editor-documents (app-editor a5)))
                (length (editor-documents (app-editor a4))))

  (delete-directory/files d)
  (displayln "lab-rebuild/app.rkt: all tests passed"))
