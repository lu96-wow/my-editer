#lang racket

(require "../../core/editor.rkt"
         "../platform/state.rkt"
         "../platform/panel.rkt"
         "../platform/paths.rkt"
         "../platform/input.rkt"
         "../platform/keymap.rkt"
         "../platform/command.rkt"
         "../platform/hooks.rkt"
         "edit.rkt")

;;; lab-rebuild/builtin/buffers.rkt —— 文档 / 视图列表面板（内置包）
;;;
;;; 两级列表：每个 document 一行，展开的 document 紧跟它的 view 行。
;;; 面板只读；每帧 post-command 时按需重建（内容不变就不动，保留滚动位置）。
;;; 通过 panel-provider-register! / keymap-define / define-command 接入。

(provide make-buffers-panel buffers-panel-refresh! buffers-row-at-focus
         ;; 模型（可测）
         (struct-out buffer-row)
         buffers buffers? buffers-toggle! buffers-expand! buffers-collapse! buffers-expanded?
         buffers-rows buffers->document buffers-line->row buffers-refresh!
         buf-face-current buf-face-file buf-face-untitled buf-face-view)

;;; ================= 模型 =================

(struct buffer-row (kind did vid name path depth) #:transparent)
;; kind : 'doc | 'view；vid : view 行才有

(struct buffers% (expanded) #:mutable #:transparent)
(define (buffers) (buffers% (make-hash)))
(define (buffers? x) (buffers%? x))
(define (buffers-expanded? b did) (and (hash-ref (buffers%-expanded b) did #f) #t))
(define (buffers-expand! b did) (hash-set! (buffers%-expanded b) did #t) (void))
(define (buffers-collapse! b did) (hash-remove! (buffers%-expanded b) did) (void))
(define (buffers-toggle! b did)
  (if (buffers-expanded? b did) (buffers-collapse! b did) (buffers-expand! b did)))

(define buf-face-current 'buf-current)
(define buf-face-file 'buf-file)
(define buf-face-untitled 'buf-untitled)
(define buf-face-view 'buf-view)

(define (buffers-rows ed b #:exclude [exclude '()] #:path-of [path-of (lambda (did) #f)])
  (append*
   (for/list ([did (in-list (editor-document-id-list ed))] #:unless (memv did exclude))
     (define name (editor-document-name ed did))
     (define path (path-of did))
     (cons (buffer-row 'doc did #f name path 0)
           (if (buffers-expanded? b did)
               (for/list ([vid (in-list (editor-document-view-list ed did))])
                 (buffer-row 'view did vid (format "view ~a" vid) path 1))
               '())))))

(define (row-text r)
  (string-append (make-string (* 2 (buffer-row-depth r)) #\space)
                 (buffer-row-name r)))

(define (row-face r current-vid)
  (case (buffer-row-kind r)
    [(view) (if (eqv? (buffer-row-vid r) current-vid) buf-face-current buf-face-view)]
    [else (if (buffer-row-path r) buf-face-file buf-face-untitled)]))

(define (buffers->document ed b [current-vid #f] #:exclude [exclude '()] #:path-of [path-of (lambda (did) #f)])
  (define rows (buffers-rows ed b #:exclude exclude #:path-of path-of))
  (define lines (for/list ([r (in-list rows)]) (list (row-text r) (row-face r current-vid))))
  (define text (if (null? lines) "" (string-join (for/list ([ln (in-list lines)]) (first ln)) "\n")))
  (define doc (document-open text))
  (document-highlight-fill-batch
   doc (for/list ([ln (in-list lines)] [i (in-naturals)])
         (list i 0 i (string-length (first ln)) (second ln))))
  (document-readonly-fill-batch
   doc (for/list ([ln (in-list lines)] [i (in-naturals)])
         (list i 0 i (string-length (first ln)) #t)))
  doc)

(define (buffers-line->row ed b line #:exclude [exclude '()] #:path-of [path-of (lambda (did) #f)])
  (define rows (buffers-rows ed b #:exclude exclude #:path-of path-of))
  (and (exact-nonnegative-integer? line) (< line (length rows)) (list-ref rows line)))

(define (buffers-refresh! ed vid b [current-vid #f] #:exclude [exclude '()] #:path-of [path-of (lambda (did) #f)])
  (editor-view-assign! ed vid (buffers->document ed b current-vid #:exclude exclude #:path-of path-of))
  (void))

;;; ================= 面板 =================

(define (buffers-panel-refresh! a)
  (define p (app-panel a 'buffers))
  (when p
    (define ed (app-ed a))
    (define vid (panel-vid p))
    (define doc (buffers->document ed (panel-data p)
                                   (app-edit-active a)
                                   #:exclude (app-internal-vids a)
                                   #:path-of (lambda (did) (path-table-path (app-paths a) did))))
    ;; 内容不变就不重设（保留光标 / 滚动）；变了才 assign。
    (unless (equal? (editor-view-string ed vid) (document->string doc))
      (editor-view-assign! ed vid doc))))

(define (buffers-row-at-focus a)
  (define p (app-panel a 'buffers))
  (and p
       (buffers-line->row (app-ed a) (panel-data p)
                          (editor-view-point-line (app-ed a) (panel-vid p))
                          #:exclude (app-internal-vids a)
                          #:path-of (lambda (did) (path-table-path (app-paths a) did)))))

;;; ================= 动作 =================

(define (app-bufs-activate! a)
  (define row (buffers-row-at-focus a))
  (define p (app-panel a 'buffers))
  (case (and row (buffer-row-kind row))
    [(doc)  (buffers-toggle! (panel-data p) (buffer-row-did row)) (buffers-panel-refresh! a)]
    [(view) (app-show-view! a (buffer-row-vid row))]
    [else (void)]))

(define (app-bufs-new-view! a)
  (define row (buffers-row-at-focus a))
  (define did (and row (buffer-row-did row)))
  (when did
    (define-values (ed2 _v2) (editor-add-view (app-ed a) did (app-main-w a) (app-main-h a)
                                              #:line-numbers? #t))
    (set-app-ed! a ed2)
    (buffers-expand! (panel-data (app-panel a 'buffers)) did)
    (buffers-panel-refresh! a)))

(define (app-bufs-close! a)
  (define row (buffers-row-at-focus a))
  (case (and row (buffer-row-kind row))
    [(view) (app-close-view! a (buffer-row-vid row))]
    [(doc)  (app-close-document! a (buffer-row-did row))]
    [else (void)]))

;;; ================= 键表 + 命令 =================

(define buffers-keys
  (keymap-define 'buffers
   (key 'tab)       'toggle-left
   (key 'enter)     'bufs-activate
   (key 'n 'ctrl)   'bufs-new-view
   (key 'backspace) 'bufs-close))

(define (cmd-bufs-activate e a) (app-bufs-activate! a))
(define (cmd-bufs-new-view e a) (app-bufs-new-view! a))
(define (cmd-bufs-close e a)    (app-bufs-close! a))

(define-command bufs-activate cmd-bufs-activate)
(define-command bufs-new-view cmd-bufs-new-view)
(define-command bufs-close    cmd-bufs-close)

;;; ================= 面板 provider =================

(define (make-buffers-panel ctx)
  (define ed (panel-context-ed ctx))
  (define b (buffers))
  (define doc (buffers->document ed b #f))
  (define-values (ed2 _did vid)
    (editor-add-document-view ed doc (panel-context-width ctx) (panel-context-height ctx) "*buffers*"))
  (values ed2
          (panel 'buffers vid buffers-keys b
                 (lambda (a)
                   (hook-add! a 'post-command (lambda (app) (buffers-panel-refresh! app)))
                   (buffers-panel-refresh! a)))))

(void (panel-provider-register! make-buffers-panel))
