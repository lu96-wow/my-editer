#lang racket

;;; lab-re-rebuild/builtin/buffers.rkt —— 缓冲区/视图树（left dock）。
;;;
;;; 两级树：每个 document 一行；展开的 document 紧跟它的每个 view 一行。
;;; 一个 document 可以有多个 view（分屏）——在这里新建 / 切换 / 关闭。
;;; 「逻辑独立」：列哪些、怎么显示、哪些键，全在本模块；kernel 只提供 dock 机制。
;;; 只经 document-api 读元数据（路径 / 脏）；不 require document 实现。

(require racket/string
         "../kernel/api.rkt"
         "../config/keys.rkt"
         "document-api.rkt")

(provide register-buffers!)

;;; ================= 模型 =================

;; dock 自身承载的文档（*status* / *input* / *tree* / *buffers*）不算缓冲区。
(define (internal-dids ctx)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (for/list ([d (in-list (workspace-docks (session-workspace s)))])
    (editor-view-document-id ed (dock-vid d))))

(struct brow (kind did vid name path depth) #:transparent)
;; kind : 'doc | 'view

(define (buffer-dids ctx)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (define internal (internal-dids ctx))
  (for/list ([did (in-list (editor-document-id-list ed))]
             #:unless (memv did internal))
    did))

;; 展开集：did -> #t（放 service，特性的运行时状态）。
(define (buffers-init ctx) (service-put ctx 'buffers-expanded (make-hash)))
(define (buffer-expanded ctx)
  (define v (service-ref ctx 'buffers-expanded))
  (if v v (let ([h (make-hash)]) (service-put ctx 'buffers-expanded h) h)))
(define (buffer-expanded? ctx did) (and (hash-ref (buffer-expanded ctx) did #f) #t))
(define (buffer-toggle! ctx did)
  (define h (buffer-expanded ctx))
  (if (hash-ref h did #f) (hash-remove! h did) (hash-set! h did #t)))
(define (buffer-expand! ctx did) (hash-set! (buffer-expanded ctx) did #t))

(define (buffer-rows ctx)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (for/list ([did (in-list (buffer-dids ctx))])
    (define name (editor-document-name ed did))
    (define path (doc-path ctx did))
    (cons (brow 'doc did #f name path 0)
          (if (buffer-expanded? ctx did)
              (for/list ([vid (in-list (editor-document-view-list ed did))])
                (brow 'view did vid (format "view ~a" vid) path 1))
              '()))))

(define (current-did ctx)
  (define s (ctx-session ctx))
  (define vid (session-edit-vid s))
  (and vid (editor-view-document-id (session-editor s) vid)))

(define (row-text ctx r)
  (define pre
    (case (brow-kind r)
      [(doc) (if (buffer-expanded? ctx (brow-did r)) "▾ " "▸ ")]
      [else "  "]))
  (string-append (make-string (* 2 (brow-depth r)) #\space) pre (brow-name r)))

(define (row-face ctx r)
  (case (brow-kind r)
    [(view) (if (eqv? (brow-vid r) (session-focus-vid (ctx-session ctx))) 'buf-current 'buf-view)]
    [else (cond
            [(eqv? (brow-did r) (current-did ctx)) 'buf-current]
            [(brow-path r) 'buf-file]
            [else 'buf-untitled])]))

(define (buffers->document ctx)
  (define rows (append* (buffer-rows ctx)))
  (define lines (for/list ([r (in-list rows)]) (row-text ctx r)))
  (define text (if (null? lines) "" (string-join lines "\n")))
  (define doc (document-open text))
  (document-face-fill-batch
   doc (for/list ([r (in-list rows)] [l (in-list lines)] [i (in-naturals)])
         (list i 0 i (string-length l) (row-face ctx r))))
  (document-readonly-fill-batch
   doc (for/list ([l (in-list lines)] [i (in-naturals)])
         (list i 0 i (string-length l) #t)))
  doc)

;;; ================= dock 装配 =================

(define (buffers-make root ed w h)
  (define-values (ed2 _did vid) (editor-add-document-view ed (document-open "") w h "*buffers*"))
  (values ed2 vid))

(define buffers-keys
  (keytable-merge
   (list dock-base
         (kbd (key 'enter)     'buffers-activate
              (key 'up)        '(nav up #f)
              (key 'down)      '(nav down #f)
              (key 'n 'ctrl)   'buffers-new-view
              (key 'l 'ctrl)   '(buffers-open lr)
              (key 'k 'ctrl)   '(buffers-open tb)
              (key 'backspace) 'buffers-close
              (key 'escape)    'buffers-toggle))))

(define buffers-spec (dock-spec 'buffers 'left 24 #f buffers-make buffers-keys))

(define (buffers-vid ctx)
  (workspace-dock-vid (session-workspace (ctx-session ctx)) 'buffers))

(define (buffers-hook ctx _args)
  (define vid (buffers-vid ctx))
  (if vid (list (e-reload vid (buffers->document ctx))) '()))

;;; ================= 命令 =================

(define (row-at-focus ctx)
  (define s (ctx-session ctx))
  (define vid (session-focus-vid s))
  (cond
    [(not vid) #f]
    [else
     (define rows (append* (buffer-rows ctx)))
     (define line (editor-view-point-line (session-editor s) vid))
     (and (< line (length rows)) (list-ref rows line))]))

(define (cmd-buffers-activate ctx ev)
  (define r (row-at-focus ctx))
  (case (and r (brow-kind r))
    [(doc) (buffer-toggle! ctx (brow-did r)) '()]
    [(view) (list (e-show-view (brow-vid r) #t))]
    [else '()]))

(define (cmd-buffers-new-view ctx ev)
  (define r (row-at-focus ctx))
  (define did (and r (brow-did r)))
  (cond
    [(not did) '()]
    [else (buffer-expand! ctx did) (list (e-view-new did))]))

;; 按 dir 分屏打开选中的 view / 文档（而非覆盖当前编辑区）。
(define (cmd-buffers-open ctx ev dir)
  (define r (row-at-focus ctx))
  (cond
    [(not r) '()]
    [(eq? (brow-kind r) 'view) (list (e-show-view (brow-vid r) #t (list 'split dir)))]
    [else (list (e-doc-show (brow-did r) (list 'split dir) #t))]))

(define (cmd-buffers-close ctx ev)
  (define r (row-at-focus ctx))
  (case (and r (brow-kind r))
    [(view) (list (e-view-close (brow-vid r)))]
    [(doc) (list (e-close (list (brow-did r))))]
    [else '()]))

(define (cmd-buffers-toggle ctx ev)
  (define s (ctx-session ctx))
  (define d (workspace-dock (session-workspace s) 'buffers))
  (cond
    [(not d) '()]
    [(dock-visible? d) (list (e-dock-visible 'buffers #f) e-focus-restore)]
    [else (list (e-dock-visible 'buffers #t) (e-focus-push (dock-vid d)))]))

;; 轮换同侧 dock 现由内核 `e-dock-cycle` 统一处理（dock-base 的 Tab）；本模块不再自带。

(define (register-buffers! r)
  (for/fold ([r r])
            ([c (in-list (list (contrib 'init 'buffers buffers-init)
                               (contrib 'dock 'buffers buffers-spec)
                               (contrib 'hook 'buffers (make-hook 'before-render buffers-hook))
                               (contrib 'command 'buffers-activate cmd-buffers-activate)
                               (contrib 'command 'buffers-new-view cmd-buffers-new-view)
                               (contrib 'command 'buffers-open cmd-buffers-open)
                               (contrib 'command 'buffers-close cmd-buffers-close)
                               (contrib 'command 'buffers-toggle cmd-buffers-toggle)))])
    (reg-add r c)))
