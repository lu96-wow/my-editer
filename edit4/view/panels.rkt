#lang racket

;;; edit4/view/panels.rkt —— 面板：纯投影 + 集中写回
;;;
;;; 一个面板 = 一个 panel-spec(name, render)；render : World × vid -> (values text faces)。
;;; project-panels 是**纯**函数（读 World/Frozen feature）；commit-panels! 才写引擎。
;;; 面板就是文档（不可编辑），游标/选择复用文档游标。

(provide (struct-out panel-spec) (struct-out panel-registry)
         make-panel-registry panel-register panel-lookup panel-names
         base-panels
         project-panels commit-panels!
         (struct-out tree) tree-init refresh-tree! tree-rows)

(require racket/list racket/path
         "../core/world.rkt"
         "../content/engine.rkt"
         "../content/content.rkt"
         "../content/fs.rkt")

;;; ---------- 注册表 ----------

(struct panel-spec (name render) #:transparent)     ; render : World × vid -> (values text faces)
(struct panel-registry (specs) #:transparent)

(define (make-panel-registry [specs '()])
  (panel-registry
   (for/fold ([acc '()]) ([s (in-list specs)])
     (cons s (filter (lambda (x) (not (equal? (panel-spec-name x) (panel-spec-name s)))) acc)))))

(define (panel-register reg spec)
  (make-panel-registry (cons spec (panel-registry-specs reg))))

(define (panel-lookup reg name)
  (for/first ([s (in-list (panel-registry-specs reg))] #:when (equal? name (panel-spec-name s))) s))

(define (panel-names reg) (map panel-spec-name (panel-registry-specs reg)))

(define (panel-vid w name)
  (define c (world-content w))
  (and c (content-panel-vid c name)))

;;; ---------- 投影（纯） ----------

(define (project-panels reg w)
  (filter values
          (for/list ([spec (in-list (panel-registry-specs reg))])
            (define v (panel-vid w (panel-spec-name spec)))
            (and v
                 (let-values ([(text faces) ((panel-spec-render spec) w v)])
                   (list (panel-spec-name spec) v text faces))))))

;;; ---------- 写回（集中） ----------

(define (commit-panels! ed projections)
  (for ([p (in-list projections)])
    (match-define (list _name v text faces) p)
    (cond
      [(not text) (void)]
      [else
       (define old-line (view-line ed v))
       (define old-col (view-col ed v))
       (unless (equal? text (view-string ed v))
         (assign! ed v text)
         (define ls (string-split text "\n"))
         (define ln (if (null? ls) 0 (min old-line (sub1 (length ls)))))
         (define lc (if (null? ls) 0 (min old-col (string-length (list-ref ls ln)))))
         (set-point! ed v ln lc))
       (for ([f (in-list faces)]) (face-line! ed (view-did ed v) (car f) (cdr f)))])))

;;; ---------- 状态栏 ----------

(define (status-content w v)
  (define c (world-content w))
  (define fv (and (world-focus w) (content-vid-of c (world-focus w))))
  (define ed (content-ed c))
  (cond
    [(not fv) (values "" '())]
    [else
     (define did (view-did ed fv))
     (define m (content-doc-meta c did))
     (define path (doc-path m))
     (define name (if path (path->string (file-name-from-path path)) (view-document-name ed fv)))
     (define dirty (if (doc-dirty? c did) " *" ""))
     (values (format " ~a~a   ~a:~a" name dirty (add1 (view-line ed fv)) (add1 (view-col ed fv)))
             (list (cons 0 'status-bar)))]))

;;; ---------- 文件树 ----------

(struct tree (root expanded children) #:transparent)

(define (tree-init root) (tree (simplify-path (path->complete-path root)) (hash) (hash)))

(define (tree-ensure ts)                            ; IO：读目录快照到缓存
  (define dirs (cons (tree-root ts) (hash-keys (tree-expanded ts))))
  (define ch
    (for/fold ([ch (tree-children ts)]) ([d (in-list dirs)] #:unless (hash-has-key? ch d))
      (hash-set ch d (with-handlers ([exn:fail? (lambda (_) '())]) (fs-read-dir d)))))
  (struct-copy tree ts [children ch]))

;; IO：刷新树的目录缓存（boot / 重载时调用，不在每帧投影里）
(define (refresh-tree! w #:root [root (current-directory)])
  (define ts (feature-ref w 'tree #f))
  (feature-set w 'tree (tree-ensure (if ts ts (tree-init root)))))

;; 可见行：(path name dir? depth)
(define (tree-rows ts)
  (define (walk dir depth)
    (append*
     (for/list ([e (in-list (hash-ref (tree-children ts) dir '()))])
       (define p (car e)) (define d? (cdr e))
       (cons (list p (path->string (file-name-from-path p)) d? depth)
             (if (and d? (hash-has-key? (tree-expanded ts) p)) (walk p (add1 depth)) '())))))
  (define root (tree-root ts))
  (cons (list root (path->string root) #t 0) (walk root 1)))

(define (tree-content w v)
  (define ts (feature-ref w 'tree #f))
  (cond
    [(not ts) (values "" '())]
    [else
     (define rows (tree-rows ts))
     (define lines
       (for/list ([r (in-list rows)])
         (define nm (list-ref r 1))
         (string-append (make-string (* 2 (list-ref r 3)) #\space)
                        (if (list-ref r 2) (string-append nm "/") nm))))
     (values (string-join lines "\n")
             (for/list ([r (in-list rows)] [i (in-naturals)])
               (cons i (if (list-ref r 2) 'tree-dir 'tree-file))))]))

;;; ---------- 基础注册表 ----------

(define base-panels
  (make-panel-registry (list (panel-spec "*status*" status-content)
                             (panel-spec "*tree*" tree-content))))
