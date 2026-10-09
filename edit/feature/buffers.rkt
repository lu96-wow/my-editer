#lang racket

;;; edit/feature/buffers.rkt —— 文档 / 视图管理窗口（左侧）
;;;
;;; 两级树：每个 document 一行；展开的 document 紧跟它的每个 view 一行。
;;; 在这里切换 / 新建（分屏）/ 关闭视图与文档。只读。
;;;
;;; 状态窗口（panel）自身不算缓冲区。

(require "api.rkt"
         "../document/lifecycle.rkt")   ; 关闭（脏则问）

(provide buffers-install
         (struct-out cmd-buffers-activate) (struct-out cmd-buffers-new-view)
         (struct-out cmd-buffers-open) (struct-out cmd-buffers-close)
         (struct-out cmd-buffers-toggle))

;;; ---------- 模型 ----------

(struct brow (kind did vid name) #:transparent)
;; kind : 'doc | 'view

(define (rows s model)
  (define internal (session-panel-dids s))
  (append*
   (for/list ([did (in-list (session-document-ids s))] #:unless (memv did internal))
     (define name (session-document-name s did))
     (cons (brow 'doc did #f name)
           (if (hash-ref model did #f)
               (for/list ([vid (in-list (session-view-ids-of s did))])
                 (brow 'view did vid (format "view ~a" vid)))
               '())))))

(define (row-at-focus s model vid)
  (define line (session-view-point-line s vid))
  (define rs (rows s model))
  (and (< line (length rs)) (list-ref rs line)))

(define (edit-did s)
  (define vid (session-edit-vid s))
  (and vid (session-view-did s vid)))

(define (row-face s r)
  (case (brow-kind r)
    [(view) (if (eqv? (brow-vid r) (session-focus-vid s)) 'buf-current 'buf-view)]
    [else (if (eqv? (brow-did r) (edit-did s)) 'buf-current 'buf-file)]))

(define (buffers-document s model)
  (panel-doc
   (for/list ([r (in-list (rows s model))])
     (list (case (brow-kind r)
             [(doc) (string-append (if (hash-ref model (brow-did r) #f) "▾ " "▸ ") (brow-name r))]
             [else (string-append "   " (brow-name r))])
           (row-face s r)))))

;; 内容（行 + 焦点 / 活动视图）没变就返回 #f，避免每帧重装。
(define (make-refresh model last)
  (lambda (s)
    (define key (list (rows s model) (session-edit-vid s) (session-focus-vid s)))
    (cond [(equal? key (unbox last)) #f]
          [else (set-box! last key) (buffers-document s model)])))

;;; ---------- 命令 ----------

(struct cmd-buffers-activate  () #:transparent)
(struct cmd-buffers-new-view () #:transparent)
(struct cmd-buffers-open     (dir) #:transparent)
(struct cmd-buffers-close    () #:transparent)
(struct cmd-buffers-toggle   () #:transparent)

(define (do-activate s model vid)
  (define r (row-at-focus s model vid))
  (cond
    [(not r) s]
    [(eq? (brow-kind r) 'doc)
     (if (hash-ref model (brow-did r) #f)
         (hash-remove! model (brow-did r))
         (hash-set! model (brow-did r) #t))
     s]
    [else (session-show-view s (brow-vid r))]))

(define (do-new-view s model vid)
  (define r (row-at-focus s model vid))
  (define did (and r (brow-did r)))
  (cond
    [(not did) s]
    [else
     (define vs (session-view-ids-of s did))
     (cond [(null? vs) s]
           [else (hash-set! model did #t)
                 (session-split-view s (first vs) 'lr)])]))

(define (do-open s model vid dir)
  (define r (row-at-focus s model vid))
  (cond
    [(not r) s]
    [(eq? (brow-kind r) 'view) (session-split-view s (brow-vid r) dir)]
    [else
     (define vs (session-view-ids-of s (brow-did r)))
     (cond [(null? vs) s]
           [else (hash-set! model (brow-did r) #t)
                 (session-split-view s (first vs) dir)])]))

(define (do-close s model vid)
  (define r (row-at-focus s model vid))
  (case (and r (brow-kind r))
    [(view) (session-close-view-checked s (brow-vid r))]
    [(doc)  (session-close-doc s (brow-did r))]
    [else s]))

(define (do-toggle s vid)
  (session-set-visible s vid (not (session-visible? s vid))))

(define (buffers-handler model vid)
  (lambda (s cmd)
    (and (eqv? vid (session-focus-vid s))
         (cond
           [(cmd-buffers-activate? cmd)  (do-activate s model vid)]
           [(cmd-buffers-new-view? cmd)  (do-new-view s model vid)]
           [(cmd-buffers-open? cmd)      (do-open s model vid (cmd-buffers-open-dir cmd))]
           [(cmd-buffers-close? cmd)     (do-close s model vid)]
           [(cmd-buffers-toggle? cmd)    (session-set-visible s vid (not (session-visible? s vid)))]
           [else #f]))))

;;; ---------- 装配 ----------

(define buffers-keys
  (kbd
   (key 'up)        (cmd-nav 'up #f)
   (key 'down)      (cmd-nav 'down #f)
   (key 'enter)     (cmd-buffers-activate)
   (key 'n 'ctrl)   (cmd-buffers-new-view)
   (key 'l 'ctrl)   (cmd-buffers-open 'lr)
   (key 'k 'ctrl)   (cmd-buffers-open 'tb)
   (key 'backspace) (cmd-buffers-close)
   (key 'd 'ctrl)   (cmd-buffers-close)
   (key 'escape)    (cmd-buffers-toggle)
   (key 'tab)       (cmd-panel-swap)))

;; → (values session vid)
(define (buffers-install s width height)
  (define-values (s1 _did vid) (session-add-document s "" width height #:name "*buffers*"))
  (define model (make-hash))
  (define p (panel 'buffers vid (make-refresh model (box #f)) buffers-keys 'left 1))
  (define s2 (session-add-panel s1 p))
  (values (session-add-handler s2 (buffers-handler model vid)) vid))
