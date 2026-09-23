#lang racket

;;; default-editor/shell.rkt —— 装配：editor ⊕ panels ⊕ layout ⊕ 命令
;;;
;;; shell 是 default-editor 的**唯一装配点**，刻意保持薄：
;;;
;;;   · 状态：editor（唯一状态源）+ layout（几何）+ 一组 panel + focus
;;;   · 组件之间不认识彼此；前端 / 文件树 / 状态栏只通过 panel 协议被 shell 调度
;;;   · 唯一的耦合点：
;;;       ① layout —— 谁在哪个矩形、是否可见（窗口显隐）
;;;       ② 命令   —— 输入路由 + 跨组件动作（如「树里回车 → 前端打开文件」）
;;;
;;; 两个生命周期被刻意分开：
;;;   · 窗口显隐：shell-set-visible? / layout 开关。**不动任何 document**。
;;;   · 文档开关：shell-open-file / shell-close-buffer（前端 buffer），或组件的 *-close。
;;;
;;; shell->screen 仍输出后端无关的 screen；terminal.rkt 才画成字节。

(require "../core/editor.rkt"
         "../core/api.rkt"
         "layout.rkt"
         "panel.rkt"
         "frontend.rkt"
         "tree.rkt"
         "status.rkt"
         racket/file racket/path racket/list racket/string rackunit)

(provide
 shell? shell-open shell-refresh shell-sync shell-resize
 ;; 读口
 shell-editor shell-ed shell-layout shell-focus shell-panels shell-panel
 shell-frontend shell-tree shell-status
 shell-active-did shell-main-did shell-main-vid shell-path shell-name shell-message
 shell-sidebar? shell-status? shell-pane-visible? shell-buffers shell->string
 ;; 窗口显隐（与文档无关）
 shell-set-visible? shell-toggle-pane shell-toggle-sidebar
 shell-set-sidebar? shell-set-sidebar-width shell-set-status? shell-set-status-height
 ;; 文档生命周期（buffer）
 shell-open-text shell-open-file shell-close-buffer shell-switch-buffer
 shell-next-buffer shell-prev-buffer shell-write-file
 ;; 焦点
 shell-focus-at shell-toggle-focus
 ;; 编辑命令
 shell-undo shell-redo shell-toggle-line-numbers shell-set-message shell-clear-message
 ;; 投影 / 输入
 shell->screen shell-default-provider shell-handle
 shell-text shell-key shell-click shell-wheel
 ;; 组件原语的口（方便整层替换 / 测试）
 shell-tree-key shell-tree-enter shell-tree-current?)

;;; ---------- 值 ----------

(struct shell (ed layout focus panels) #:transparent)
;; ed     : editor             唯一状态源（文档 / 视图 / 历史）
;; layout : layout             几何 + 窗口显隐（耦合点 ①）
;; focus  : symbol             焦点 pane id（'frontend / 'tree / 'status）
;; panels : (listof panel)     顺序 = 合成顺序

;;; ---------- 构造 ----------

(define (shell-open [path #f] [rows 24] [cols 80]
                    #:root [root (current-directory)]
                    #:sidebar? [sidebar? #t]
                    #:sidebar-width [sidebar-width 30]
                    #:status? [status? #t]
                    #:status-height [status-height 1])
  (define l0 (layout-open rows cols
                          #:sidebar? sidebar? #:sidebar-width sidebar-width
                          #:status? status? #:status-height status-height))
  (define m (layout-frontend l0))
  (define text (cond [(and path (file-exists? path)) (file->string path)] [else ""]))
  (define name (cond [path (path->string (file-name-from-path path))] [else "*scratch*"]))
  (define-values (ed1 fe)
    (frontend-create text (max 1 (rect-h m)) (max 1 (rect-w m)) #:path path #:name name))
  (define tr (layout-tree l0))
  (define-values (ed2 tree)
    (tree-open ed1 root (max 1 (rect-h tr)) (max 1 (rect-w tr)) #:current path))
  (define sr (layout-status l0))
  (define-values (ed3 status)
    (status-open ed2 (max 1 (rect-h sr)) (max 1 (rect-w sr))
                 #:source (frontend-active-vid fe)))
  (shell-refresh
   (shell ed3 l0 'frontend
          (list (frontend-panel fe) (tree-panel tree) (status-panel status)))))

;;; ---------- panel 读写 ----------

(define (shell-panel s id)
  (or (for/first ([p (in-list (shell-panels s))] #:when (eq? id (panel-id p))) p)
      (error 'shell-panel "没有这个 pane: ~a" id)))

(define (shell-put-panel s id p)
  (struct-copy shell s
    [panels (for/list ([q (in-list (shell-panels s))] #:when #t)
              (if (eq? id (panel-id q)) p q))]))

(define (shell-put-state s id st)
  (shell-put-panel s id (panel-set-state (shell-panel s id) st)))

(define (shell-map-panels s f)          ; f : editor panel -> (values editor panel)
  (define-values (ed ps)
    (for/fold ([ed (shell-ed s)] [ps '()]) ([p (in-list (shell-panels s))])
      (define-values (ed* p*) (f ed p))
      (values ed* (cons p* ps))))
  (struct-copy shell s [ed ed][panels (reverse ps)]))

(define (shell-frontend s) (panel-state (shell-panel s 'frontend)))
(define (shell-tree s)     (panel-state (shell-panel s 'tree)))
(define (shell-status s)   (panel-state (shell-panel s 'status)))
(define (shell-editor s)   (shell-ed s))

;;; ---------- 读口 ----------

(define (shell-active-did s) (frontend-active-did (shell-frontend s)))
(define (shell-main-did s) (shell-active-did s))
(define (shell-main-vid s) (frontend-active-vid (shell-frontend s)))
(define (shell-path s) (frontend-path (shell-frontend s)))
(define (shell-name s) (frontend-name (shell-frontend s)))
(define (shell-message s) (status-message (shell-status s)))
(define (shell-sidebar? s) (layout-sidebar? (shell-layout s)))
(define (shell-status? s) (layout-status? (shell-layout s)))
(define (shell-pane-visible? s id) (layout-pane-visible? (shell-layout s) id))
(define (shell-buffers s) (frontend-buffers (shell-frontend s)))
(define (shell->string s) (frontend-string (shell-ed s) (shell-frontend s)))

(define (shell-default-provider ed did line) (default-provider ed did line))

;;; ---------- 刷新（几何 / 派生） ----------

;; 状态栏描述的是前端当前文档 —— 切换 buffer 后要先把 source 指过去。
(define (shell-update-source s)
  (define st (shell-status s))
  (shell-put-state s 'status (status-with-source st (frontend-active-vid (shell-frontend s)))))

;; 全量：重算布局尺寸 → 写回每个 pane → 全量刷新（树重扫 fs）。
(define (shell-refresh s)
  (define l (layout-normalize (shell-layout s)))
  (define s1 (shell-update-source (struct-copy shell s [layout l])))
  (define s2 (shell-map-panels s1
               (lambda (ed p) (panel-resize ed p (layout-rect l (panel-id p))))))
  (shell-map-panels s2 (lambda (ed p) (panel-refresh ed p))))

;; 廉价：编辑后只重算派生内容（状态栏），不重扫 fs。
(define (shell-sync s)
  (shell-map-panels (shell-update-source s) (lambda (ed p) (panel-sync ed p))))

(define (shell-resize s rows cols)
  (define l (shell-layout s))
  (shell-refresh
   (struct-copy shell s
     [layout (layout-open rows cols
                          #:sidebar? (layout-sidebar? l)
                          #:sidebar-width (layout-sidebar-width l)
                          #:status? (layout-status? l)
                          #:status-height (layout-status-height l))])))

;;; ---------- 窗口显隐（与文档无关） ----------

;; 只改 layout 开关 + panel.visible?；**不动任何 document**。
(define (shell-set-visible? s id on?)
  (define l* (layout-set-visible? (shell-layout s) id on?))
  (define s1 (struct-copy shell s [layout l*]))
  (define s2 (shell-put-panel s1 id (panel-set-visible? (shell-panel s1 id) on?)))
  (define s3 (if (and (not on?) (eq? (shell-focus s2) id))
                 (struct-copy shell s2 [focus 'frontend])
                 s2))
  (shell-focus-at (shell-refresh s3) (shell-focus s3)))

(define (shell-toggle-pane s id) (shell-set-visible? s id (not (layout-pane-visible? (shell-layout s) id))))
(define (shell-toggle-sidebar s) (shell-toggle-pane s 'tree))
(define (shell-set-sidebar? s on?) (shell-set-visible? s 'tree on?))
(define (shell-set-status? s on?) (shell-set-visible? s 'status on?))

(define (shell-set-sidebar-width s w)
  (shell-refresh (struct-copy shell s [layout (layout-set-sidebar-width (shell-layout s) w)])))
(define (shell-set-status-height s h)
  (shell-refresh (struct-copy shell s [layout (layout-set-status-height (shell-layout s) h)])))

;;; ---------- 焦点 ----------

(define (shell-focus-at s id)
  (unless (memq id '(frontend tree status))
    (error 'shell-focus-at "焦点必须是 'frontend / 'tree / 'status，得到 ~a" id))
  (cond
    [(not (layout-pane-visible? (shell-layout s) id)) s]
    [else
     (define ed (case id
                  [(frontend) (frontend-focus (shell-ed s) (shell-frontend s))]
                  [(tree) (editor-focus-view (shell-ed s) (tree-view (shell-tree s)))]
                  [(status) (shell-ed s)]))
     (struct-copy shell s [ed ed][focus id])]))

(define (shell-toggle-focus s)
  (case (shell-focus s)
    [(tree) (shell-focus-at s 'frontend)]
    [else (if (layout-pane-visible? (shell-layout s) 'tree) (shell-focus-at s 'tree) s)]))

;;; ---------- 消息 ----------

(define (shell-set-message s msg)
  (define-values (ed st*) (status-set-message (shell-ed s) (shell-status s) msg))
  (shell-put-state (struct-copy shell s [ed ed]) 'status st*))
(define (shell-clear-message s) (shell-set-message s #f))

;;; ---------- 文档生命周期（buffer） ----------

(define (shell-tree-set-current s path)
  (define t (tree-set-current (shell-tree s) (and path (path->complete-path path))))
  (shell-put-state s 'tree t))

(define (shell-focus-frontend s) (shell-focus-at s 'frontend))

(define (shell-open-text s path text)
  (define-values (ed fe*) (frontend-add (shell-ed s) (shell-frontend s) text
                                        #:path path
                                        #:name (if path (path->string (file-name-from-path path)) "*scratch*")))
  (shell-sync (shell-focus-frontend (shell-tree-set-current (struct-copy shell s [ed ed]) path))))

(define (shell-open-file s path)
  (define-values (ed fe* _did msg)
    (frontend-open-file (shell-ed s) (shell-frontend s) path))
  (define s1 (shell-tree-set-current (struct-copy shell s [ed ed]) path))
  (define s2 (shell-put-state s1 'frontend fe*))
  (define s3 (shell-focus-frontend s2))
  (shell-sync (if msg (shell-set-message s3 msg) s3)))

(define (shell-close-buffer s [did (shell-active-did s)])
  (define-values (ed fe*) (frontend-close (shell-ed s) (shell-frontend s) did))
  (shell-sync (shell-focus-frontend (shell-put-state (struct-copy shell s [ed ed]) 'frontend fe*))))

(define (shell-switch-buffer s did)
  (define-values (ed fe*) (frontend-switch (shell-ed s) (shell-frontend s) did))
  (shell-sync (shell-focus-frontend (shell-put-state (struct-copy shell s [ed ed]) 'frontend fe*))))

(define (shell-next-buffer s)
  (define-values (ed fe*) (frontend-next (shell-ed s) (shell-frontend s)))
  (shell-sync (shell-focus-frontend (shell-put-state (struct-copy shell s [ed ed]) 'frontend fe*))))

(define (shell-prev-buffer s)
  (define-values (ed fe*) (frontend-prev (shell-ed s) (shell-frontend s)))
  (shell-sync (shell-focus-frontend (shell-put-state (struct-copy shell s [ed ed]) 'frontend fe*))))

(define (shell-write-file s [path #f])
  (define-values (ed fe* ok? msg)
    (frontend-save (shell-ed s) (shell-frontend s) path))
  (values (shell-sync (shell-set-message (shell-put-state (struct-copy shell s [ed ed]) 'frontend fe*) msg))
          ok?))

;;; ---------- 编辑命令 ----------

(define (shell-undo s)
  (define-values (ed _r) (frontend-undo (shell-ed s) (shell-frontend s)))
  (shell-sync (struct-copy shell s [ed ed])))

(define (shell-redo s)
  (define-values (ed _r) (frontend-redo (shell-ed s) (shell-frontend s)))
  (shell-sync (struct-copy shell s [ed ed])))

(define (shell-toggle-line-numbers s)
  (shell-sync (struct-copy shell s
               [ed (frontend-toggle-line-numbers (shell-ed s) (shell-frontend s))])))

;;; ---------- 投影 ----------

(define (shell->screen s)
  (define l (layout-normalize (shell-layout s)))
  (define ed (shell-ed s))
  (define panes
    (for/list ([p (in-list (shell-panels s))]
               #:when (and (panel-visible? p) (layout-pane-visible? l (panel-id p))))
      (define r (layout-rect l (panel-id p)))
      (pane (panel-id p) (rect-x r) (rect-y r) (panel-project ed p))))
  (screen-compose (layout-rows l) (layout-cols l) panes (shell-focus s)))

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
    [(eq? (shell-focus s) 'frontend)
     (define-values (ed _r) (frontend-text (shell-ed s) (shell-frontend s) str))
     (shell-sync (struct-copy shell s [ed ed]))]
    [else s]))

(define (shell-key s k mods)
  (define c? (mod? mods modifiers-control))
  (define a? (mod? mods modifiers-alt))
  (define sh? (mod? mods modifiers-shift))
  (cond
    [(and c? (char? k)) (shell-ctrl s (char-downcase k))]
    [(and c? (memq k '(pagedown pageup)))
     (values (if (eq? k 'pagedown) (shell-next-buffer s) (shell-prev-buffer s)) #f)]
    [(eq? k 'escape) (shell-escape s)]
    [(eq? (shell-focus s) 'tree) (shell-tree-key s k sh?)]
    [(eq? (shell-focus s) 'frontend)
     (define-values (ed _r) (frontend-key (shell-ed s) (shell-frontend s) k a? sh?))
     (values (shell-sync (struct-copy shell s [ed ed])) #f)]
    [else (values s #f)]))

(define (shell-ctrl s c)
  (case c
    [(#\q) (values s #t)]
    [(#\s) (define-values (s1 _ok) (shell-write-file s)) (values s1 #f)]
    [(#\w) (values (shell-toggle-focus s) #f)]
    [(#\b) (values (shell-toggle-sidebar s) #f)]
    [(#\z) (values (shell-undo s) #f)]
    [(#\y) (values (shell-redo s) #f)]
    [(#\n) (values (shell-toggle-line-numbers s) #f)]
    [(#\x) (values (shell-close-buffer s) #f)]
    [else (values s #f)]))

(define (shell-escape s)
  (cond
    [(eq? (shell-focus s) 'tree) (values (shell-focus-at s 'frontend) #f)]
    [else
     (define ed (shell-ed s))
     (define fe (shell-frontend s))
     (define vid (frontend-active-vid fe))
     (define sels (editor-view-selections ed vid))
     (if (or (> (length sels) 1) (for/or ([sel (in-list sels)]) (not (caret? sel))))
         (values (shell-sync (struct-copy shell s [ed (frontend-collapse ed fe)])) #f)
         (values s #t))]))

(define (shell-tree-current? s) (tree-current (shell-tree s)))

(define (shell-tree-key s k shift?)
  (define ed (shell-ed s)) (define t (shell-tree s))
  (define (finish ed* t*)
    (shell-put-state (struct-copy shell s [ed ed*]) 'tree t*))
  (case k
    [(up) (let-values ([(e t*) (tree-up ed t)]) (values (finish e t*) #f))]
    [(down) (let-values ([(e t*) (tree-down ed t)]) (values (finish e t*) #f))]
    [(home) (let-values ([(e t*) (tree-home ed t)]) (values (finish e t*) #f))]
    [(end) (let-values ([(e t*) (tree-end ed t)]) (values (finish e t*) #f))]
    [(left) (let-values ([(e t*) (tree-collapse ed t)]) (values (finish e t*) #f))]
    [(right) (let-values ([(e t*) (tree-expand ed t)]) (values (finish e t*) #f))]
    [(enter return space) (shell-tree-enter s)]
    [else (values s #f)]))

(define (shell-tree-enter s)
  (define-values (ed t act) (tree-enter (shell-ed s) (shell-tree s)))
  (define s1 (shell-put-state (struct-copy shell s [ed ed]) 'tree t))
  (cond
    [(not act) (values s1 #f)]
    [(eq? (tree-action-kind act) 'open) (values (shell-open-file s1 (tree-action-path act)) #f)]
    [else (values s1 #f)]))

(define (shell-click s x y _button)
  (define l (layout-normalize (shell-layout s)))
  (case (layout-region-at l x y)
    [(tree)
     (define s1 (shell-focus-at s 'tree))
     (define tr (layout-rect l 'tree))
     (define-values (ed t) (tree-goto-line (shell-ed s1) (shell-tree s1) (- y (rect-y tr))))
     (values (shell-put-state (struct-copy shell s1 [ed ed]) 'tree t) #f)]
    [(frontend)
     (define s1 (shell-focus-at s 'frontend))
     (define m (layout-rect l 'frontend))
     (define ed (shell-ed s1)) (define vid (frontend-active-vid (shell-frontend s1)))
     (define-values (line col) (editor-view-screen->point ed vid (- y (rect-y m)) (- x (rect-x m))))
     (cond [(not line) (values s1 #f)]
           [else (values (shell-sync (struct-copy shell s1
                                       [ed (editor-view-goto ed vid (point line col))])) #f)])]
    [else (values s #f)]))

(define (shell-wheel s x y dir)
  (define l (layout-normalize (shell-layout s)))
  (define delta (case dir [(up) -3] [(down) 3] [else 0]))
  (case (layout-region-at l x y)
    [(frontend)
     (define ed (shell-ed s))
     (define vid (frontend-active-vid (shell-frontend s)))
     (values (shell-sync (struct-copy shell s [ed (editor-view-scroll ed vid delta)])) #f)]
    [(tree)
     (values (shell-put-state (struct-copy shell s
                                [ed (editor-view-scroll (shell-ed s) (tree-view (shell-tree s)) delta)])
                              'tree (shell-tree s))
             #f)]
    [else (values s #f)]))

;;; ---------- 测试 ----------

(module+ test
  (require "../core/editor.rkt" "../core/api.rkt" "buffer.rkt")
  (define dir (make-temporary-file "edshell~a" 'directory))
  (call-with-output-file (build-path dir "a.txt") #:exists 'replace (lambda (o) (display "abc" o)))

  (define s0 (shell-open #f 20 60 #:root dir))
  (check-true (shell? s0))
  (check-equal? (shell-focus s0) 'frontend)
  (check-true (shell-sidebar? s0))
  (check-true (shell-status? s0))
  (check-true (screen? (shell->screen s0)))
  (check-equal? (screen-height (shell->screen s0)) 20)
  (check-equal? (screen-width (shell->screen s0)) 60)

  ;; 编辑走前端
  (define s1 (shell-text s0 "hi"))
  (check-equal? (shell->string s1) "hi")

  ;; 键盘：左移 / 右移（编辑后光标在文末 (0,2)）
  (define-values (s2 _q2) (shell-key s1 'left #f))
  (check-equal? (editor-view-point (shell-ed s2) (shell-main-vid s2)) (point 0 1))
  (define-values (s2b _q2b) (shell-key s2 'right #f))
  (check-equal? (editor-view-point (shell-ed s2b) (shell-main-vid s2b)) (point 0 2))

  ;; 窗口显隐 ≠ 关文档：
  ;; 关侧栏后，buffer 数量 / 文档数不变
  (define docs-before (editor-document-count (shell-ed s1)))
  (define s3 (shell-toggle-sidebar s1))
  (check-false (shell-sidebar? s3))
  (check-equal? (rect-x (layout-frontend (shell-layout s3))) 0)
  (check-equal? (editor-document-count (shell-ed s3)) docs-before)
  (check-equal? (buffers-count (shell-buffers s3)) (buffers-count (shell-buffers s1)))
  ;; 再打开也还在
  (check-true (shell-sidebar? (shell-toggle-sidebar s3)))
  ;; 关状态栏同理
  (define s3b (shell-set-status? s1 #f))
  (check-false (shell-status? s3b))
  (check-equal? (editor-document-count (shell-ed s3b)) docs-before)

  ;; 焦点切到文件树并导航
  (define s4 (shell-focus-at s1 'tree))
  (check-equal? (shell-focus s4) 'tree)
  (define-values (s5 _q5) (shell-key s4 'down #f))
  (check-equal? (shell-focus s5) 'tree)
  (define-values (s6 _q6) (shell-key s5 'escape #f))
  (check-equal? (shell-focus s6) 'frontend)

  ;; 打开文件 → 新 buffer（旧 scratch 不关）
  (define s7 (shell-open-file s1 (build-path dir "a.txt")))
  (check-equal? (shell-path s7) (build-path dir "a.txt"))
  (check-equal? (shell->string s7) "abc")
  (check-equal? (buffers-count (shell-buffers s7)) 2)
  (check-equal? (tree-current (shell-tree s7)) (build-path dir "a.txt"))

  ;; 切 buffer
  (define s7b (shell-switch-buffer s7 0))
  (check-equal? (shell->string s7b) "hi")
  (define s7c (shell-next-buffer s7b))
  (check-equal? (shell->string s7c) "abc")

  ;; 关 buffer：只关文档，不动窗口显隐
  (define s7d (shell-close-buffer s7c))
  (check-equal? (buffers-count (shell-buffers s7d)) 1)
  (check-true (shell-sidebar? s7d))
  (check-true (shell-status? s7d))

  ;; 写盘
  (define out (build-path dir "out.txt"))
  (define-values (s8 ok) (shell-write-file s7 out))
  (check-true ok)
  (check-equal? (file->string out) "abc")
  (check-true (string-contains? (shell-message s8) "saved"))

  ;; resize
  (define s9 (shell-resize s8 10 40))
  (check-equal? (screen-height (shell->screen s9)) 10)
  (check-equal? (screen-width (shell->screen s9)) 40)

  ;; Ctrl+Q → quit；Ctrl+B → 开关侧栏；Ctrl+X → 关 buffer
  (define-values (_s10 q10) (shell-key s9 #\q (modifiers #t #f #f #f)))
  (check-true q10)
  (define-values (s11 _q11) (shell-key s0 #\b (modifiers #t #f #f #f)))
  (check-false (shell-sidebar? s11))
  (define s12 (shell-open-file s0 (build-path dir "a.txt")))
  (define-values (s13 _q13) (shell-key s12 #\x (modifiers #t #f #f #f)))
  (check-equal? (buffers-count (shell-buffers s13)) 1)

  ;; core 事件入口
  (define-values (s14 _q14) (shell-handle s0 (text-event "Z" (modifiers #f #f #f #f))))
  (check-equal? (shell->string s14) "Z")

  (delete-directory/files dir)
  (displayln "shell.rkt: all tests passed"))
