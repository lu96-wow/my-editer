#lang racket

;;; lab-rebuild/builtin/panels.rkt —— 左栏面板：文档/视口树（buffers）+ 面板轮换。
;;;
;;; buffers 是**两级树**：每个 document 一行；展开的 document 紧跟它的每个 view 一行。
;;; 一个 document 可以有多个 view（分屏），在这里可新建 / 切换 / 关闭。
;;; 面板只读，每帧 before-render 刷新（内容不变则不动）。

(require racket/string
         "../kernel/api.rkt")

(provide register-panels!)

;;; ================= 公共：内部视图 / 面板查找 =================

(define (internal-dids s)
  (define ed (session-editor s))
  (for/list ([v (in-list (append (list (session-status-vid s) (session-input-vid s))
                                 (for/list ([p (in-list (session-panels s))]) (panel-vid p))))])
    (editor-view-document-id ed v)))

(define (panel-by-name s name)
  (for/first ([p (in-list (session-panels s))] #:when (eq? (panel-name p) name)) p))

(define (current-panel s)
  (or (panel-by-name s (session-active-panel s))
      (and (pair? (session-panels s)) (car (session-panels s)))))

;;; ================= buffers 模型 =================

(struct buffers-model (expanded) #:mutable #:transparent)

(define (buffers-expanded? m did) (and (hash-ref (buffers-model-expanded m) did #f) #t))
(define (buffers-toggle! m did)
  (define h (buffers-model-expanded m))
  (if (hash-ref h did #f) (hash-remove! h did) (hash-set! h did #t)))
(define (buffers-expand! m did) (hash-set! (buffers-model-expanded m) did #t))

(struct buffer-row (kind did vid name path depth) #:transparent)
;; kind : 'doc | 'view

(define (buf-rows ctx m)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (define internal (internal-dids s))
  (append*
   (for/list ([did (in-list (editor-document-id-list ed))] #:unless (memv did internal))
     (define name (editor-document-name ed did))
     (define path (path-table-path (session-paths s) did))
     (cons (buffer-row 'doc did #f name path 0)
           (if (buffers-expanded? m did)
               (for/list ([vid (in-list (editor-document-view-list ed did))])
                 (buffer-row 'view did vid (format "view ~a" vid) path 1))
               '())))))

(define (row-text r)
  (string-append (make-string (* 2 (buffer-row-depth r)) #\space) (buffer-row-name r)))

(define (row-face r current-vid)
  (case (buffer-row-kind r)
    [(view) (if (eqv? (buffer-row-vid r) current-vid) 'buf-current 'buf-view)]
    [else (if (buffer-row-path r) 'buf-file 'buf-untitled)]))

(define (buffers->document ctx m)
  (define current (session-focus-vid (ctx-session ctx)))
  (define rows (buf-rows ctx m))
  (define lines (for/list ([r (in-list rows)]) (list (row-text r) (row-face r current))))
  (define text (if (null? lines) "" (string-join (for/list ([l (in-list lines)]) (first l)) "\n")))
  (define doc (document-open text))
  (document-highlight-fill-batch
   doc (for/list ([l (in-list lines)] [i (in-naturals)])
         (list i 0 i (string-length (first l)) (second l))))
  (document-readonly-fill-batch
   doc (for/list ([l (in-list lines)] [i (in-naturals)])
         (list i 0 i (string-length (first l)) #t)))
  doc)

(define (buf-row-at-focus ctx)
  (define s (ctx-session ctx))
  (define vid (session-focus-vid s))
  (define p (panel-by-name s 'buffers))
  (cond
    [(or (not vid) (not p)) #f]
    [else
     (define rows (buf-rows ctx (panel-data p)))
     (define line (editor-view-point-line (session-editor s) vid))
     (and (< line (length rows)) (list-ref rows line))]))

;;; ================= buffers 命令 =================

(define (cmd-panel-activate ctx ev)
  (define row (buf-row-at-focus ctx))
  (case (and row (buffer-row-kind row))
    [(doc) (buffers-toggle! (panel-data (panel-by-name (ctx-session ctx) 'buffers))
                            (buffer-row-did row))
           '()]
    [(view) (list (e-show-view (buffer-row-vid row) #t))]
    [else '()]))

(define (cmd-bufs-new-view ctx ev)
  (define row (buf-row-at-focus ctx))
  (define did (and row (buffer-row-did row)))
  (cond
    [(not did) '()]
    [else (buffers-expand! (panel-data (panel-by-name (ctx-session ctx) 'buffers)) did)
          (list (e-view-new did))]))

(define (cmd-bufs-close ctx ev)
  (define row (buf-row-at-focus ctx))
  (case (and row (buffer-row-kind row))
    [(view) (list (e-view-close (buffer-row-vid row)))]
    [(doc) (list (e-close (list (buffer-row-did row))))]
    [else '()]))

;;; ================= buffers panel =================

(define (make-buffers _root ed w h)
  (define-values (ed2 _did vid) (editor-add-document-view ed (document-open "") w h "*buffers*"))
  (values ed2 vid (buffers-model (make-hash))))

(define (refresh-buffers ctx vid data)
  (list (e-reload vid (buffers->document ctx data))))

(define buffers-panel
  (panel-spec 'buffers 0 make-buffers
              (list (kbd (key 'enter)     'panel-activate
                         (key 'tab)       'toggle-left
                         (key 'n 'ctrl)   'bufs-new-view
                         (key 'backspace) 'bufs-close))
              refresh-buffers))

;;; ================= 侧栏 / 面板轮换 =================

(define (cmd-toggle-sidebar ctx ev)
  (define s (ctx-session ctx))
  (define p (current-panel s))
  (cond
    [(session-sidebar? s) (list (e-sidebar #f) (e-focus 'restore))]
    [p (list (e-sidebar #t) (e-focus-push (panel-vid p)))]
    [else (list (e-sidebar #t))]))

(define (cmd-toggle-left ctx ev)
  (define s (ctx-session ctx))
  (define names (for/list ([p (in-list (session-panels s))]) (panel-name p)))
  (cond
    [(null? names) '()]
    [else
     (define cur (session-active-panel s))
     (define idx (or (for/first ([n (in-list names)] [i (in-naturals)] #:when (eq? n cur)) i) -1))
     (define next (list-ref names (modulo (add1 idx) (length names))))
     (define p (panel-by-name s next))
     (list (e-active-panel next) (e-sidebar #t)
           (if p (e-focus-push (panel-vid p)) (e-focus 'restore)))]))

;;; ================= 每帧刷新 =================

(define (panels-hook ctx _args)
  (define s (ctx-session ctx))
  (append* (for/list ([p (in-list (session-panels s))])
             ((panel-spec-refresh (panel-pspec p)) ctx (panel-vid p) (panel-data p)))))

(define (register-panels! r)
  (for/fold ([r r]) ([c (in-list (list (contrib 'panel 'buffers 0 buffers-panel)
                                       (contrib 'command 'panel-activate 0 cmd-panel-activate)
                                       (contrib 'command 'bufs-new-view 0 cmd-bufs-new-view)
                                       (contrib 'command 'bufs-close 0 cmd-bufs-close)
                                       (contrib 'command 'toggle-sidebar 0 cmd-toggle-sidebar)
                                       (contrib 'command 'toggle-left 0 cmd-toggle-left)
                                       (contrib 'hook 'panels 0 (make-hook 'before-render panels-hook))))])
    (reg-add r c)))
