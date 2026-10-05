#lang racket

(require "../../core/editor.rkt")

;;; lab-rebuild/ui/buffers.rkt —— 打开的文档 + 其视图（两级，像文件树）
;;;
;;;   buffers    模型：哪些 document 展开了（默认收起）
;;;   buffer-row 一行：kind（'doc | 'view）+ did [+ vid] + 名字 + depth
;;;
;;; 行序：每个 doc 一行；展开的 doc 紧跟它的 view 行（缩进一层）。
;;; 选中 doc：展开/收起它的 view；选中 view：打开该 view。
;;; 合成面板（文件树 / 自己 / 底部槽位）用 #:exclude 排除。
;;;
;;; 本层不认识 app / 路径表：did → path 用 #:path-of 回调注入。

(provide (struct-out buffer-row)
         buffers buffers? buffers-toggle! buffers-expand! buffers-collapse! buffers-expanded?
         buffers-rows buffers->document buffers-line->row buffers-refresh!
         buf-face-current buf-face-file buf-face-untitled buf-face-view)

(struct buffer-row (kind did vid name path depth) #:transparent)
;; kind : 'doc | 'view；vid : view 行才有

(struct buffers% (expanded) #:mutable #:transparent)
;; expanded : 可变 hash did -> #t（展开的文档）

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

;; 模型 → 原生 document。current-vid = 当前编辑格的视图（高亮）。
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
