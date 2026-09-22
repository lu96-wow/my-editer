#lang racket

;;; default-editor/shell.rkt —— 打包的默认编辑器：editor ⊕ 组件 ⊕ 布局 ⊕ 焦点
;;;
;;; core 不管**窗口管理**（分区 / 拼屏 / 焦点路由）。本层把「一个 editor + 左栏文件树
;;; + 底部状态栏 + 布局几何」包成一个不可变值 `shell`，操作全是 `shell -> shell`
;;; （输入路径返回 `(values shell quit?)`），投影 `shell->screen` 仍输出后端无关的 screen。
;;;
;;; 分工：
;;;   · editor 是唯一状态源（文档 / 视图 / 历史）；
;;;   · layout 决定三块矩形，每次变化把三个 view 的尺寸写回 editor；
;;;   · tree / status 是派生 document，refresh 只在与当前文本不同才写；
;;;   · 焦点 = 'main | 'tree（由 editor-focus 派生），状态栏永不聚焦；
;;;   · 按键的默认映射在这里；键位是应用策略，可以整层替换（直接用 shell-* 语义操作）。

(require "../core/editor.rkt"
         "../core/api.rkt"
         "layout.rkt"
         "status.rkt"
         "tree.rkt"
         racket/file racket/path racket/list racket/string rackunit)

(provide
 shell? shell-open shell-refresh shell-resize
 shell-editor shell-tree shell-status shell-layout shell-main-vid shell-path shell-message shell-main-did
 shell-focus shell-focus-at shell-sidebar?
 shell-set-sidebar? shell-toggle-sidebar shell-set-sidebar-width shell-set-status-height
 shell-set-message shell-clear-message
 shell-toggle-line-numbers
 shell-open-text shell-open-file shell-write-file shell->string
 shell->screen shell-default-provider
 shell-handle shell-text shell-key shell-click shell-wheel
 shell-undo shell-redo)

;;; ---------- 值 ----------

(struct shell (ed tree status layout main-vid path) #:transparent)
;; ed       : editor   唯一状态源
;; tree     : tree     左栏文件树
;; status   : status   底部状态栏
;; layout   : layout   分区几何（已 normalize）
;; main-vid : vid      主编辑 view（打开文件就换它的 document）
;; path     : (or/c path #f)  当前文件

(define shell-editor shell-ed)

;;; ---------- 构造 ----------

(define (shell-open [path #f] [rows 24] [cols 80]
                    #:root [root (current-directory)]
                    #:sidebar? [sidebar? #t]
                    #:sidebar-width [sidebar-width 30]
                    #:status-height [status-height 1])
  (define text (cond [(and path (file-exists? path)) (file->string path)] [else ""]))
  (define name (cond [path (path->string (file-name-from-path path))] [else "*scratch*"]))
  (define l0 (layout-open rows cols #:sidebar? sidebar? #:sidebar-width sidebar-width
                          #:status-height status-height))
  (define m (layout-main l0))
  (define ed0 (editor-open text (max 1 (rect-h m)) (max 1 (rect-w m)) #:name name))
  (define main-vid 0)
  (define tr (layout-tree l0))
  (define-values (ed1 tree) (tree-open ed0 root (max 1 (rect-h tr)) (max 1 (rect-w tr))
                                       #:current path))
  (define st (layout-status l0))
  (define-values (ed2 status) (status-open ed1 (max 1 (rect-h st)) (max 1 (rect-w st))
                                           #:source main-vid))
  (shell-refresh (shell ed2 tree status l0 main-vid path)))

;;; ---------- 查询 ----------

(define (shell-main-did s) (editor-view-document-id (shell-ed s) (shell-main-vid s)))
(define (shell->string s) (editor-document->string (shell-ed s) (shell-main-did s)))
(define (shell-message s) (status-message (shell-status s)))
(define (shell-sidebar? s) (layout-sidebar? (shell-layout s)))

(define (shell-focus s)
  (define vid (editor-focus (shell-ed s)))
  (if (and (tree-view (shell-tree s)) (equal? vid (tree-view (shell-tree s)))) 'tree 'main))

;;; ---------- 布局 / 刷新 ----------

(define (shell-refresh s)
  (define l (layout-normalize (shell-layout s)))
  (define m (layout-main l)) (define tr (layout-tree l)) (define st (layout-status l))
  (define ed (shell-ed s))
  (define ed1 (editor-view-set-size ed (shell-main-vid s) (max 1 (rect-h m)) (max 1 (rect-w m))))
  (define ed2 (editor-view-set-size ed1 (tree-view (shell-tree s)) (max 1 (rect-h tr)) (max 1 (rect-w tr))))
  (define ed3 (editor-view-set-size ed2 (status-view (shell-status s)) (max 1 (rect-h st)) (max 1 (rect-w st))))
  (define-values (ed4 tree) (tree-refresh ed3 (shell-tree s)))
  (define-values (ed5 status) (status-refresh ed4 (shell-status s)))
  (struct-copy shell s [ed ed5][tree tree][status status][layout l]))

(define (shell-resize s rows cols)
  (define l (shell-layout s))
  (shell-refresh (struct-copy shell s
                  [layout (layout-open rows cols
                                       #:sidebar? (layout-sidebar? l)
                                       #:sidebar-width (layout-sidebar-width l)
                                       #:status-height (layout-status-height l))])))

(define (shell-focus-at s where)
  (case where
    [(main) (struct-copy shell s [ed (editor-focus-view (shell-ed s) (shell-main-vid s))])]
    [(tree) (if (and (layout-sidebar? (shell-layout s)) (> (layout-sidebar-width (shell-layout s)) 0))
                (struct-copy shell s [ed (editor-focus-view (shell-ed s) (tree-view (shell-tree s)))])
                s)]
    [else (error 'shell-focus "where 必须是 'main / 'tree，得到 ~a" where)]))

(define (shell-toggle-focus s)
  (if (eq? (shell-focus s) 'tree) (shell-focus-at s 'main) (shell-focus-at s 'tree)))

(define (shell-set-sidebar? s on?)
  (shell-refresh (struct-copy shell s [layout (layout-set-sidebar? (shell-layout s) on?)])))
(define (shell-toggle-sidebar s) (shell-set-sidebar? s (not (shell-sidebar? s))))
(define (shell-set-sidebar-width s w)
  (shell-refresh (struct-copy shell s [layout (layout-set-sidebar-width (shell-layout s) w)])))
(define (shell-set-status-height s h)
  (shell-refresh (struct-copy shell s [layout (layout-set-status-height (shell-layout s) h)])))

;;; ---------- 消息 ----------

(define (shell-set-message s msg)
  (define-values (ed st) (status-set-message (shell-ed s) (shell-status s) msg))
  (struct-copy shell s [ed ed][status st]))
(define (shell-clear-message s) (shell-set-message s #f))

;;; ---------- 文件 ----------

;; 换主 view 的 document（新文档、保留视图矩形与焦点），关掉旧文档。
(define (shell-open-text s path text)
  (define ed (shell-ed s))
  (define mvid (shell-main-vid s))
  (define old-did (editor-view-document-id ed mvid))
  (define m (layout-main (layout-normalize (shell-layout s))))
  (define name (cond [path (path->string (file-name-from-path path))] [else "*scratch*"]))
  (define-values (ed1 new-did) (editor-open-document ed text (max 1 (rect-h m)) (max 1 (rect-w m))
                                                     #:name name #:focus? #f #:history? #t))
  (define auto-vid (editor-document-view ed1 new-did))
  (define ed2 (editor-view-set-document ed1 mvid new-did))   ; 主视图指向新文档
  (define ed3 (editor-close-view ed2 auto-vid))              ; 去掉新文档自带的 view
  (define ed4 (editor-close-document ed3 old-did))           ; 关旧文档
  (define t1 (tree-set-current (shell-tree s) path))
  (shell-refresh (struct-copy shell s [ed ed4][tree t1][path path])))

(define (shell-open-file s path)
  (cond [(not (file-exists? path)) (shell-set-message s (format "no such file: ~a" path))]
        [else (shell-open-text s path (file->string path))]))

(define (shell-write-file s [path (shell-path s)])
  (cond
    [(not path) (values (shell-set-message s "no file name") #f)]
    [else
     (call-with-output-file path #:exists 'replace
       (lambda (o) (write-string (shell->string s) o)))
     (values (shell-set-message s (format "saved ~a" path)) #t)]))

;;; ---------- 投影 ----------

;; 主文档默认 face：读 'face 属性键当 face；read-only 保留键映射成只读样式。
(define (shell-default-provider ed did line)
  (define faces (editor-document-attrs-key-runs ed did line 'face))
  (define ros (editor-document-attrs-key-runs ed did line read-only-key))
  (append (for/list ([r (in-list faces)]) (list (car r) (cadr r) (caddr r)))
          (for/list ([r (in-list ros)]) (list (car r) (cadr r) (hash 'face 'read-only)))))

(define (shell->screen s #:face-provider [prov shell-default-provider])
  (define ed (shell-ed s))
  (define l (layout-normalize (shell-layout s)))
  (define m (layout-main l)) (define tr (layout-tree l)) (define st (layout-status l))
  (define panes
    (append
     (list (pane 'main (rect-x m) (rect-y m)
                 (editor-view->screen ed (shell-main-vid s) prov)))
     (if (and (layout-sidebar? l) (> (layout-sidebar-width l) 0))
         (list (pane 'tree (rect-x tr) (rect-y tr) (tree-screen ed (shell-tree s))))
         '())
     (if (> (layout-status-height l) 0)
         (list (pane 'status (rect-x st) (rect-y st) (status-screen ed (shell-status s))))
         '())))
  (screen-compose (layout-rows l) (layout-cols l) panes
                  (if (eq? (shell-focus s) 'tree) 'tree 'main)))

;;; ---------- 输入 ----------

(define (mod? m f) (and m (f m)))

(define (shell-handle s ev)
  (cond
    [(text-event? ev) (values (shell-text s (text-event-text ev)) #f)]
    [(key-event? ev) (shell-key s (key-event-key ev) (key-event-modifiers ev))]
    [(resize-event? ev) (values (shell-resize s (resize-event-rows ev) (resize-event-cols ev)) #f)]
    [(mouse-press-event? ev)
     (values (shell-click s (mouse-press-event-x ev) (mouse-press-event-y ev)
                          (mouse-press-event-button ev)) #f)]
    [(mouse-wheel-event? ev)
     (values (shell-wheel s (mouse-wheel-event-x ev) (mouse-wheel-event-y ev)
                          (mouse-wheel-event-direction ev)) #f)]
    [(quit-event? ev) (values s #t)]
    [else (values s #f)]))

(define (shell-text s str)
  (cond
    [(eq? (shell-focus s) 'main)
     (define-values (ed _r) (editor-view-edit (shell-ed s) (shell-main-vid s) (edit-insert str)))
     (shell-refresh (struct-copy shell s [ed ed]))]
    [else s]))

(define (shell-key s k mods)
  (define c? (mod? mods modifiers-control))
  (define a? (mod? mods modifiers-alt))
  (define sh? (mod? mods modifiers-shift))
  (cond
    [(and c? (char? k)) (shell-ctrl s (char-downcase k))]
    [(eq? k 'escape) (shell-escape s)]
    [(eq? (shell-focus s) 'tree) (shell-tree-key s k sh?)]
    [else (shell-main-key s k a? sh?)]))

(define (shell-ctrl s c)
  (case c
    [(#\q) (values s #t)]
    [(#\s) (define-values (s1 _ok) (shell-write-file s)) (values s1 #f)]
    [(#\w) (values (shell-toggle-focus s) #f)]
    [(#\b) (values (shell-toggle-sidebar s) #f)]
    [(#\z) (values (shell-undo s) #f)]
    [(#\y) (values (shell-redo s) #f)]
    [(#\n) (values (shell-toggle-line-numbers s) #f)]
    [else (values s #f)]))

(define (shell-escape s)
  (cond
    [(eq? (shell-focus s) 'tree) (values (shell-focus-at s 'main) #f)]
    [else
     (define ed (shell-ed s))
     (define vid (shell-main-vid s))
     (define sels (editor-view-selections ed vid))
     (if (or (> (length sels) 1) (for/or ([sel (in-list sels)]) (not (caret? sel))))
         (values (shell-refresh (struct-copy shell s [ed (editor-view-collapse-selections ed vid)])) #f)
         (values s #t))]))

(define (shell-undo s)
  (define-values (ed _r) (editor-view-undo (shell-ed s) (shell-main-vid s)))
  (shell-refresh (struct-copy shell s [ed ed])))
(define (shell-redo s)
  (define-values (ed _r) (editor-view-redo (shell-ed s) (shell-main-vid s)))
  (shell-refresh (struct-copy shell s [ed ed])))

(define (shell-toggle-line-numbers s)
  (define ed (shell-ed s)) (define vid (shell-main-vid s))
  (shell-refresh (struct-copy shell s
                  [ed (editor-view-set-line-numbers ed vid (not (editor-view-line-numbers? ed vid)))])))

(define (shell-main-key s k alt? shift?)
  (define ed (shell-ed s))
  (define vid (shell-main-vid s))
  (define (fin ed*) (values (shell-refresh (struct-copy shell s [ed ed*])) #f))
  (cond
    [alt?
     (case k
       [(up) (fin (editor-view-add-selection ed vid
                    (caret (editor-view-point-up ed vid (editor-view-point ed vid)))))]
       [(down) (fin (editor-view-add-selection ed vid
                      (caret (editor-view-point-down ed vid (editor-view-point ed vid)))))]
       [else (values s #f)])]
    [shift?
     (case k
       [(left right up down home end) (shell-extend s k)]
       [else (values s #f)])]
    [else
     (case k
       [(left) (fin (editor-view-left ed vid))]
       [(right) (fin (editor-view-right ed vid))]
       [(up) (fin (editor-view-up ed vid))]
       [(down) (fin (editor-view-down ed vid))]
       [(home) (fin (editor-view-home ed vid))]
       [(end) (fin (editor-view-end ed vid))]
       [(pageup) (fin (editor-view-scroll ed vid (- (editor-view-height ed vid))))]
       [(pagedown) (fin (editor-view-scroll ed vid (editor-view-height ed vid)))]
       [(enter return newline) (shell-insert s "\n")]
       [(backspace) (shell-edit-op s (edit-backspace))]
       [(delete) (shell-edit-op s (edit-delete))]
       [(tab) (shell-insert s "  ")]
       [else (values s #f)])]))

(define (shell-insert s text)
  (define-values (ed _r) (editor-view-edit (shell-ed s) (shell-main-vid s) (edit-insert text)))
  (values (shell-refresh (struct-copy shell s [ed ed])) #f))

(define (shell-edit-op s op)
  (define-values (ed _r) (editor-view-edit (shell-ed s) (shell-main-vid s) op))
  (values (shell-refresh (struct-copy shell s [ed ed])) #f))

(define (shell-extend s sym)
  (define ed (shell-ed s)) (define vid (shell-main-vid s))
  (define ed* (editor-view-map-primary ed vid
                (lambda (sel)
                  (define h (selection-head sel))
                  (define h* (case sym
                               [(left) (editor-view-point-left ed vid h)]
                               [(right) (editor-view-point-right ed vid h)]
                               [(up) (editor-view-point-up ed vid h)]
                               [(down) (editor-view-point-down ed vid h)]
                               [(home) (editor-view-point-home ed vid h)]
                               [(end) (editor-view-point-end ed vid h)]))
                  (selection (selection-anchor sel) h*))))
  (values (shell-refresh (struct-copy shell s [ed ed*])) #f))

(define (shell-tree-key s k shift?)
  (define ed (shell-ed s)) (define t (shell-tree s))
  (define (finish ed* t*) (values (shell-refresh (struct-copy shell s [ed ed*][tree t*])) #f))
  (case k
    [(up) (let-values ([(e t*) (tree-up ed t)]) (finish e t*))]
    [(down) (let-values ([(e t*) (tree-down ed t)]) (finish e t*))]
    [(home) (let-values ([(e t*) (tree-home ed t)]) (finish e t*))]
    [(end) (let-values ([(e t*) (tree-end ed t)]) (finish e t*))]
    [(left) (let-values ([(e t*) (tree-collapse ed t)]) (finish e t*))]
    [(right) (let-values ([(e t*) (tree-expand ed t)]) (finish e t*))]
    [(enter return space) (shell-tree-enter s)]
    [else (values s #f)]))

(define (shell-tree-enter s)
  (define-values (ed t act) (tree-enter (shell-ed s) (shell-tree s)))
  (define s1 (struct-copy shell s [ed ed][tree t]))
  (cond
    [(not act) (values (shell-refresh s1) #f)]
    [(eq? (tree-action-kind act) 'open) (values (shell-open-file s1 (tree-action-path act)) #f)]
    [else (values (shell-refresh s1) #f)]))

(define (shell-click s x y _button)
  (define l (layout-normalize (shell-layout s)))
  (case (layout-region-at l x y)
    [(tree)
     (define s1 (shell-focus-at s 'tree))
     (define tr (layout-tree l))
     (define-values (ed t) (tree-goto-line (shell-ed s1) (shell-tree s1) (- y (rect-y tr))))
     (values (shell-refresh (struct-copy shell s1 [ed ed][tree t])) #f)]
    [(main)
     (define s1 (shell-focus-at s 'main))
     (define m (layout-main l))
     (define ed (shell-ed s1)) (define vid (shell-main-vid s1))
     (define-values (line col) (editor-view-screen->point ed vid (- y (rect-y m)) (- x (rect-x m))))
     (cond [(not line) (values s1 #f)]
           [else (values (shell-refresh (struct-copy shell s1
                                       [ed (editor-view-goto ed vid (point line col))])) #f)])]
    [else (values s #f)]))

(define (shell-wheel s x y dir)
  (define l (layout-normalize (shell-layout s)))
  (define delta (case dir [(up) -3] [(down) 3] [else 0]))
  (case (layout-region-at l x y)
    [(main) (values (shell-refresh (struct-copy shell s
                                   [ed (editor-view-scroll (shell-ed s) (shell-main-vid s) delta)])) #f)]
    [(tree) (values (shell-refresh (struct-copy shell s
                                   [ed (editor-view-scroll (shell-ed s) (tree-view (shell-tree s)) delta)])) #f)]
    [else (values s #f)]))

;;; ---------- 测试 ----------

(module+ test
  (define dir (make-temporary-file "edshell~a" 'directory))
  (call-with-output-file (build-path dir "a.txt") #:exists 'replace (lambda (o) (display "abc" o)))

  (define s0 (shell-open #f 20 60 #:root dir))
  (check-true (shell? s0))
  (check-equal? (shell-focus s0) 'main)
  (check-true (shell-sidebar? s0))
  (check-true (screen? (shell->screen s0)))
  (check-equal? (screen-height (shell->screen s0)) 20)
  (check-equal? (screen-width (shell->screen s0)) 60)

  ;; 文本编辑
  (define s1 (shell-text s0 "hi"))
  (check-equal? (shell->string s1) "hi")

  ;; 键盘：左移
  (define-values (s2 _q2) (shell-key s1 'left #f))
  (check-equal? (editor-view-point (shell-editor s2) (shell-main-vid s2)) (point 0 1))

  ;; 侧栏开关：主区从 0 开始
  (define s3 (shell-toggle-sidebar s1))
  (check-false (shell-sidebar? s3))
  (check-equal? (rect-x (layout-main (shell-layout s3))) 0)
  (check-equal? (shell-sidebar? (shell-toggle-sidebar s3)) #t)

  ;; 焦点切到文件树并导航
  (define s4 (shell-focus-at s1 'tree))
  (check-equal? (shell-focus s4) 'tree)
  (define-values (s5 _q5) (shell-key s4 'down #f))
  (check-equal? (shell-focus s5) 'tree)
  ;; Esc 从树回到主区
  (define-values (s6 _q6) (shell-key s5 'escape #f))
  (check-equal? (shell-focus s6) 'main)

  ;; 打开文件：path / 文本 / tree current
  (define s7 (shell-open-file s1 (build-path dir "a.txt")))
  (check-equal? (shell-path s7) (build-path dir "a.txt"))
  (check-equal? (shell->string s7) "abc")
  (check-equal? (tree-current (shell-tree s7)) (build-path dir "a.txt"))

  ;; 写盘
  (define out (build-path dir "out.txt"))
  (define-values (s8 ok) (shell-write-file s7 out))
  (check-true ok)
  (check-equal? (file->string out) "abc")

  ;; resize
  (define s9 (shell-resize s8 10 40))
  (check-equal? (screen-height (shell->screen s9)) 10)
  (check-equal? (screen-width (shell->screen s9)) 40)

  ;; Ctrl+Q → quit
  (define-values (_s10 q10) (shell-key s9 #\q (modifiers #t #f #f #f)))
  (check-true q10)
  ;; Ctrl+B → 开关侧栏
  (define-values (s11 _q11) (shell-key s0 #\b (modifiers #t #f #f #f)))
  (check-false (shell-sidebar? s11))

  ;; core 事件入口
  (define-values (s12 _q12) (shell-handle s0 (text-event "Z" (modifiers #f #f #f #f))))
  (check-equal? (shell->string s12) "Z")

  (delete-directory/files dir)
  (displayln "shell.rkt: all tests passed"))
