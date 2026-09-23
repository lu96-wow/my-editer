#lang racket

;;; default-editor/buffer.rkt —— 打开的文档注册表（工作区）
;;;
;;; core 的 editor 持有所有 document（含派生 UI 的树 / 状态栏）；buffer 只记**用户在编辑的
;;; 文档**：打开顺序、当前项、来自哪个文件、自己的 view、上次保存的文本版本。
;;;
;;; 它是**独立值**：只依赖 core，不认识 tree / status / frontend / shell。
;;; 生命周期与窗口解耦：buffer 只管 document 的 open / close / activate；窗口显隐是 layout 的事。
;;;
;;;   buffer-entry = did ⊕ vid ⊕ path ⊕ name ⊕ saved-tick
;;;
;;; 每个打开文档有自己的 view（光标 / 滚动 / 选区都留在 view 上），所以切换 buffer 不丢视口状态。

(require "../core/editor.rkt"
         racket/file racket/path racket/list rackunit)

(provide
 buffer-entry buffer-entry? buffer-entry-did buffer-entry-vid buffer-entry-path
 buffer-entry-name buffer-entry-saved-tick
 buffers buffers? buffers-empty buffers-count buffers-entries buffers-has?
 buffers-active buffers-active-entry buffers-entry buffers-find-path
 buffers-path buffers-name buffers-vid
 buffers-add buffers-remove buffers-activate buffers-next buffers-prev
 buffers-dirty? buffers-mark-saved buffers-rename buffers-set-path)

;;; ---------- 值 ----------

(struct buffer-entry (did vid path name saved-tick) #:transparent)
;; did        : did                   文档 id
;; vid        : vid                   该文档的 view（视口状态住在这）
;; path       : (or/c path #f)        来自哪个文件（#f = 无文件 / scratch）
;; name       : string                显示名
;; saved-tick : nat                   保存时的文本版本（与 text-tick 比 → dirty?）

(struct buffers (entries active-did) #:transparent)
;; entries    : (listof buffer-entry)    打开顺序（稳定）
;; active-did : (or/c did #f)            当前在主视图里的文档

(define (buffers-empty) (buffers '() #f))

(define (buffers-count bs) (length (buffers-entries bs)))

(define (buffers-has? bs did)
  (and did (for/or ([e (in-list (buffers-entries bs))]) (= did (buffer-entry-did e)))))

;; active 的读口：只有确实还在注册表里才算。
(define (buffers-active bs)
  (define a (buffers-active-did bs))
  (and a (buffers-has? bs a) a))

(define (buffers-active-entry bs)
  (define a (buffers-active bs))
  (and a (buffers-entry bs a)))

(define (buffers-entry bs did)
  (for/first ([e (in-list (buffers-entries bs))] #:when (and did (= did (buffer-entry-did e)))) e))

(define (buffers-find-path bs path)
  (define p (and path (path->complete-path path)))
  (for/first ([e (in-list (buffers-entries bs))]
              #:when (and p (buffer-entry-path e) (equal? p (buffer-entry-path e))))
    (buffer-entry-did e)))

(define (buffers-path bs did) (define e (buffers-entry bs did)) (and e (buffer-entry-path e)))
(define (buffers-name bs did) (define e (buffers-entry bs did)) (and e (buffer-entry-name e)))
(define (buffers-vid bs did) (define e (buffers-entry bs did)) (and e (buffer-entry-vid e)))

;;; ---------- 打开 / 关闭 / 切换（文档生命周期） ----------

;; 新开一个文档：建 document（由 editor 承载）+ 记一条 entry，并设为 active。
;; **不**碰任何 view 的尺寸 / 焦点（那是 frontend / layout 的事）。
(define (buffers-add ed bs text height width
                     #:path [path #f]
                     #:name [name "*scratch*"]
                     #:history? [history? #t]
                     #:line-numbers? [line-numbers? #f])
  (define p (and path (path->complete-path path)))
  (define-values (ed1 did) (editor-open-document ed text (max 1 height) (max 1 width)
                                                 #:name name #:focus? #f
                                                 #:history? history? #:line-numbers? line-numbers?))
  (define vid (editor-document-view ed1 did))
  (define e (buffer-entry did vid p name (editor-document-text-tick ed1 did)))
  (values ed1 (buffers (append (buffers-entries bs) (list e)) did) did))

;; 从注册表移除（纯，不关 editor 里的 document —— 关文档由调用方显式做，见 frontend-close）。
;; active 落到「原位置的下一项」，没有则前一项，再没有则 #f。
(define (buffers-remove bs did)
  (define es (buffers-entries bs))
  (define idx (for/first ([e (in-list es)] [i (in-naturals)] #:when (= did (buffer-entry-did e))) i))
  (cond
    [(not idx) bs]
    [else
     (define es* (for/list ([e (in-list es)] #:unless (= did (buffer-entry-did e))) e))
     (define old (buffers-active bs))
     (define active*
       (cond [(not (equal? old did)) old]
             [(null? es*) #f]
             [else (buffer-entry-did (list-ref es* (min idx (sub1 (length es*)))))]))
     (buffers es* active*)]))

(define (buffers-activate bs did)
  (cond [(buffers-has? bs did) (struct-copy buffers bs [active-did did])]
        [else bs]))

(define (buffers-step bs delta)
  (define es (buffers-entries bs))
  (cond
    [(null? es) bs]
    [else
     (define n (length es))
     (define i (or (for/first ([e (in-list es)] [i (in-naturals)]
                               #:when (= (buffers-active bs) (buffer-entry-did e))) i)
                   0))
     (buffers es (buffer-entry-did (list-ref es (modulo (+ i delta) n))))]))

(define (buffers-next bs) (buffers-step bs 1))
(define (buffers-prev bs) (buffers-step bs -1))

;;; ---------- 元数据 ----------
(define (buffers-dirty? ed bs [did (buffers-active bs)])
  (define e (buffers-entry bs did))
  (and e (not (= (buffer-entry-saved-tick e) (editor-document-text-tick ed did)))))

(define (buffers-mark-saved ed bs [did (buffers-active bs)])
  (define tick (editor-document-text-tick ed did))
  (struct-copy buffers bs
    [entries (for/list ([e (in-list (buffers-entries bs))])
               (if (= did (buffer-entry-did e)) (struct-copy buffer-entry e [saved-tick tick]) e))]))

(define (buffers-rename ed bs did name)
  (struct-copy buffers bs
    [entries (for/list ([e (in-list (buffers-entries bs))])
               (if (= did (buffer-entry-did e)) (struct-copy buffer-entry e [name name]) e))]))

(define (buffers-set-path bs did path)
  (define p (and path (path->complete-path path)))
  (struct-copy buffers bs
    [entries (for/list ([e (in-list (buffers-entries bs))])
               (if (= did (buffer-entry-did e)) (struct-copy buffer-entry e [path p]) e))]))

;;; ---------- 测试 ----------

(module+ test
  (define dir (make-temporary-file "edbuf~a" 'directory))
  (define a (build-path dir "a.txt"))
  (call-with-output-file a #:exists 'replace (lambda (o) (display "abc" o)))

  (define ed0 (editor-open "hello" 10 40 #:name "*scratch*"))
  (define bs0 (buffers (list (buffer-entry 0 0 #f "*scratch*" 0)) 0))
  (check-true (buffers? bs0))
  (check-equal? (buffers-count bs0) 1)
  (check-equal? (buffers-active bs0) 0)
  (check-equal? (buffers-name bs0 0) "*scratch*")
  (check-false (buffers-dirty? ed0 bs0))

  ;; 加文档：新建 did/vid，设 active，不动旧文档
  (define-values (ed1 bs1 did1) (buffers-add ed0 bs0 "xyz" 5 20 #:path a #:name "a.txt"))
  (check-equal? (buffers-count bs1) 2)
  (check-equal? (buffers-active bs1) did1)
  (check-equal? (buffers-path bs1 did1) (path->complete-path a))
  (check-equal? (buffers-find-path bs1 a) did1)
  (check-equal? (editor-document->string ed1 did1) "xyz")
  (check-equal? (editor-document->string ed1 0) "hello")     ; 旧文档还在
  (check-equal? (buffers-vid bs1 did1) (editor-document-view ed1 did1))
  (check-equal? (editor-view-width ed1 (buffers-vid bs1 did1)) 20)

  ;; dirty 由 text-tick 决定，mark-saved 后才干净
  (define-values (ed1x _r) (editor-view-edit ed1 (buffers-vid bs1 did1) (edit-insert "!")))
  (check-true (buffers-dirty? ed1x bs1 did1))
  (check-false (buffers-dirty? ed1x (buffers-mark-saved ed1x bs1 did1)))

  ;; 切换 / 轮换
  (check-equal? (buffers-active (buffers-activate bs1 0)) 0)
  (check-equal? (buffers-active (buffers-next (buffers-activate bs1 0))) did1)
  (check-equal? (buffers-active (buffers-prev (buffers-activate bs1 did1))) 0)

  ;; 关闭：active 落到邻居；空集 → #f
  (define bs2 (buffers-remove (buffers-activate bs1 did1) did1))
  (check-equal? (buffers-count bs2) 1)
  (check-equal? (buffers-active bs2) 0)
  (define bs3 (buffers-remove bs2 0))
  (check-equal? (buffers-count bs3) 0)
  (check-false (buffers-active bs3))
  (check-equal? (buffers-remove bs1 999) bs1)               ; 未知 did：恒等

  ;; 重命名 / 改路径
  (check-equal? (buffers-name (buffers-rename ed1 bs1 did1 "A") did1) "A")
  (check-equal? (buffers-path (buffers-set-path bs1 did1 a) did1) (path->complete-path a))

  (delete-directory/files dir)
  (displayln "buffer.rkt: all tests passed"))
