#lang racket

;;; default-editor/tree.rkt —— 文件树：可复用的**派生 document**
;;;
;;; 与状态栏同一套路：内容由文件系统 + 展开状态算出，物化成一个 #:history? #f 的 document。
;;; 行选择 = core 的 window 光标（上下/滚动/裁剪全部白送）；
;;; 每行 → 路径的映射存 entries（与文本同序）；face 走投影 provider。
;;;
;;; 「打开文件」这类策略不在这里：tree-enter 只回一个 tree-action，由上层决定怎么处理。

(require "../core/editor.rkt"
         "../core/api.rkt"
         "layout.rkt"
         "panel.rkt"
         racket/file racket/path racket/list racket/string rackunit)

(provide
 tree? tree-open tree-close
 tree-document-id tree-view tree-root tree-expanded tree-expanded? tree-entries tree-current tree-show-hidden?
 tree-action? tree-action-kind tree-action-path
 tree-refresh tree-rescan tree-set-root tree-set-show-hidden tree-set-current tree-set-selected
 tree-selected tree-current-line tree-goto-line
 tree-up tree-down tree-home tree-end
 tree-expand tree-collapse tree-toggle tree-enter
 tree-lines tree-provider tree-screen tree-panel)

;;; ---------- 值 ----------

(struct tree (did vid root expanded entries current show-hidden?) #:transparent)
;; did          : did                 文件树自己的 document
;; vid          : vid                 文件树的 view
;; root         : path                根目录（complete path）
;; expanded     : (listof path)        已展开目录（complete path）
;; entries      : (vectorof path)      可见行 → 路径（与文本同序）
;; current      : (or/c path #f)       主编辑器当前文件（provider 高亮）
;; show-hidden? : bool                是否显示 . 开头的项

(define tree-document-id tree-did)
(define tree-view tree-vid)
(define (tree-expanded? t p) (and (member p (tree-expanded t)) #t))

(struct tree-action (kind path) #:transparent)
;; kind ∈ 'open（文件） | 'toggle（目录）

;;; ---------- 纯逻辑：文件系统 → 行 ----------

(define (safe-directory-list dir)
  (with-handlers ([exn:fail? (lambda (_) '())])
    (directory-list dir)))

;; 目录在前、文件在后，各自按名字（忽略大小写）。
(define (sort-names names dir)
  (sort names (lambda (a b)
                (define da (directory-exists? (build-path dir a)))
                (define db (directory-exists? (build-path dir b)))
                (cond [(and da (not db)) #t]
                      [(and db (not da)) #f]
                      [else (string<? (string-downcase (path->string a))
                                      (string-downcase (path->string b)))]))))

;; 可见行（DFS）：每项 (line path)；目录展开时递归。
(define (visible-rows dir expanded show-hidden? [depth 0])
  (append*
   (for/list ([n (in-list (sort-names (safe-directory-list dir) dir))])
     (define name (path->string n))
     (define p (build-path dir n))
     (cond
       [(and (not show-hidden?) (regexp-match? #rx"^\\." name)) '()]
       [else
        (define dir? (directory-exists? p))
        (define mark (cond [(not dir?) "  "]
                           [(member p expanded) "- "]
                           [else "+ "]))
        (define line (string-append (make-string (* 2 depth) #\space) mark name))
        (define sub (if (and dir? (member p expanded))
                        (visible-rows p expanded show-hidden? (add1 depth))
                        '()))
        (cons (list line p) sub)]))))

;; 纯逻辑：给根 + 展开集，算出整棵树文本与 entries。可直接测。
(define (tree-lines root expanded #:show-hidden? [show-hidden? #f])
  (define root* (path->complete-path root))
  (define rows (visible-rows root* expanded show-hidden?))
  (values (string-join (map car rows) "\n") (map cadr rows)))

;;; ---------- 生命周期 ----------

(define (entry-line t p)
  (for/first ([e (in-vector (tree-entries t))] [i (in-naturals)] #:when (equal? e p)) i))

(define (tree-open ed root [height 24] [width 30]
                   #:name [name "*tree*"]
                   #:show-hidden? [show-hidden? #f]
                   #:current [current #f]
                   #:expanded [expanded #f])
  (define root* (path->complete-path root))
  (define exp (map path->complete-path (or expanded (list root*))))
  (define-values (text entries) (tree-lines root* exp #:show-hidden? show-hidden?))
  (define-values (ed1 did) (editor-open-document ed text (max 1 height) (max 1 width)
                                                #:name name #:focus? #f #:history? #f))
  (define vid (editor-document-view ed1 did))
  (define t (tree did vid root* exp (list->vector entries) current show-hidden?))
  (cond [(and current (entry-line t current)) (tree-set-selected ed1 t current)]
        [else (values ed1 t)]))

(define (tree-close ed t) (editor-close-document ed (tree-document-id t)))

;;; ---------- 刷新 ----------

;; 重扫 fs，重建文本 + entries；文本不变则**完全不写**。光标尽量停在原选中路径。
(define (tree-refresh ed t)
  (define-values (text entries) (tree-lines (tree-root t) (tree-expanded t)
                                            #:show-hidden? (tree-show-hidden? t)))
  (define did (tree-document-id t))
  (define sel (tree-selected ed t))
  (define cur (editor-document->string ed did))
  (define t1 (struct-copy tree t [entries (list->vector entries)]))
  (cond
    [(string=? cur text) (values ed t1)]
    [else
     (define n (editor-document-line-count ed did))
     (define p-end (point (sub1 n) (editor-document-line-length ed did (sub1 n))))
     (define-values (ed1 _r)
       (editor-command-batch ed (change (list (edit-desc (point 0 0) p-end text)) '())
                             #:view (tree-view t) #:trusted? #t #:record? #f))
     (cond [(and sel (entry-line t1 sel)) (tree-set-selected ed1 t1 sel)]
           [else (values ed1 t1)])]))

(define tree-rescan tree-refresh)

;;; ---------- 选中 / 导航 ----------

(define (tree-current-line ed t)
  (point-line (editor-view-point ed (tree-view t))))

(define (tree-selected ed t)
  (define i (tree-current-line ed t))
  (define e (tree-entries t))
  (and (< i (vector-length e)) (vector-ref e i)))

(define (tree-goto-line ed t ln)
  (define n (max 1 (vector-length (tree-entries t))))
  (define l (max 0 (min (sub1 n) ln)))
  (values (editor-view-goto ed (tree-view t) (point l 0)) t))

(define (tree-set-selected ed t p)
  (define i (entry-line t p))
  (if i (tree-goto-line ed t i) (values ed t)))

(define (tree-up ed t)   (tree-goto-line ed t (sub1 (tree-current-line ed t))))
(define (tree-down ed t) (tree-goto-line ed t (add1 (tree-current-line ed t))))
(define (tree-home ed t) (tree-goto-line ed t 0))
(define (tree-end ed t)  (tree-goto-line ed t (sub1 (vector-length (tree-entries t)))))

;;; ---------- 展开 / 收起 / 进入 ----------

(define (tree-expand ed t)
  (define p (tree-selected ed t))
  (cond [(and p (directory-exists? p) (not (tree-expanded? t p)))
         (define t1 (struct-copy tree t [expanded (cons p (tree-expanded t))]))
         (define-values (ed1 t2) (tree-refresh ed t1))
         (tree-set-selected ed1 t2 p)]
        [else (values ed t)]))

(define (tree-collapse ed t)
  (define p (tree-selected ed t))
  (cond [(and p (tree-expanded? t p))
         (define t1 (struct-copy tree t [expanded (remove p (tree-expanded t))]))
         (define-values (ed1 t2) (tree-refresh ed t1))
         (tree-set-selected ed1 t2 p)]
        [else (values ed t)]))

(define (tree-toggle ed t)
  (define p (tree-selected ed t))
  (cond [(not p) (values ed t)]
        [(tree-expanded? t p) (tree-collapse ed t)]
        [else (tree-expand ed t)]))

;; 目录 → 展开/收起；文件 → 返回 (tree-action 'open path)，由上层决定开。 
(define (tree-enter ed t)
  (define p (tree-selected ed t))
  (cond
    [(not p) (values ed t #f)]
    [(directory-exists? p) (define-values (ed1 t1) (tree-toggle ed t))
                           (values ed1 t1 (tree-action 'toggle p))]
    [else (values ed t (tree-action 'open p))]))

;;; ---------- 结构 / 配置 ----------

(define (tree-set-root ed t root)
  (define root* (path->complete-path root))
  (tree-refresh ed (struct-copy tree t [root root*][expanded (list root*)][current #f])))

(define (tree-set-show-hidden ed t on?)
  (tree-refresh ed (struct-copy tree t [show-hidden? (and on? #t)])))

(define (tree-set-current t p) (struct-copy tree t [current p]))

;;; ---------- 投影 ----------

(define (tree-provider ed t)
  (lambda (_e _did line)
    (define e (tree-entries t))
    (cond
      [(and (>= line 0) (< line (vector-length e)))
       (define p (vector-ref e line))
       (define face (cond [(and (tree-current t) (equal? (tree-current t) p)) (hash 'face 'tree-current)]
                          [(directory-exists? p) (hash 'face 'tree-dir)]
                          [else (hash 'face 'tree-file)]))
       (define text (editor-document-line-ref ed (tree-document-id t) line))
       (list (list 0 (string-length text) face))]
      [else '()])))

(define (tree-screen ed t)
  (editor-view->screen ed (tree-view t) (tree-provider ed t)))

;;; ---------- 窗格 ----------

;; 文件树窗格：只**投影 / 定尺寸 / 重扫**；输入与「打开文件」由命令层决定（见 shell）。
(define (tree-panel t)
  (panel-open 'tree t
    #:project (lambda (ed t) (tree-screen ed t))
    #:resize (lambda (ed t r)
               (values (editor-view-set-size ed (tree-view t)
                                             (max 1 (rect-h r)) (max 1 (rect-w r)))
                       t))
    #:refresh (lambda (ed t) (tree-refresh ed t))
    #:sync (lambda (ed t) (values ed t))))

;;; ---------- 测试 ----------

(module+ test
  (define dir (make-temporary-file "edtree~a" 'directory))
  (define sub (build-path dir "sub"))
  (make-directory sub)
  (for ([n (in-list '("b.rkt" "a.txt" "sub/inner.txt"))])
    (call-with-output-file (build-path dir n) #:exists 'replace (lambda (o) (display "x" o))))

  ;; 纯逻辑：目录在前、文件在后，按名排序
  (define-values (text entries) (tree-lines dir (list dir)))
  (check-equal? entries (list sub (build-path dir "a.txt") (build-path dir "b.rkt")))
  (check-true (string-contains? text "+ sub"))
  (check-true (string-contains? text "  a.txt"))

  ;; 打开 + 选中 / 导航
  (define ed (editor-open "x"))
  (define-values (ed1 t) (tree-open ed dir 10 30))
  (check-true (tree? t))
  (check-equal? (tree-selected ed1 t) sub)                       ; 目录排第一
  (define-values (ed2 t2) (tree-down ed1 t))
  (check-equal? (tree-selected ed2 t2) (build-path dir "a.txt"))

  ;; 展开目录：多出 inner.txt；光标回到被展开的目录
  (define-values (ed3 t3) (tree-set-selected ed2 t2 sub))
  (define-values (ed4 t4) (tree-expand ed3 t3))
  (check-true (tree-expanded? t4 sub))
  (check-equal? (tree-selected ed4 t4) sub)
  (check-equal? (vector-length (tree-entries t4)) 4)

  ;; 收起
  (define-values (ed5 t5) (tree-collapse ed4 t4))
  (check-false (tree-expanded? t5 sub))
  (check-equal? (vector-length (tree-entries t5)) 3)

  ;; 文件上 Enter → open 动作；目录上 Enter → toggle
  (define-values (ed6 t6) (tree-set-selected ed5 t5 (build-path dir "b.rkt")))
  (define-values (_ed7 _t7 act) (tree-enter ed6 t6))
  (check-true (tree-action? act))
  (check-equal? (tree-action-kind act) 'open)
  (check-equal? (tree-action-path act) (build-path dir "b.rkt"))
  (define-values (ed8 t8) (tree-set-selected ed5 t5 sub))
  (define-values (_ed9 _t9 act2) (tree-enter ed8 t8))
  (check-equal? (tree-action-kind act2) 'toggle)

  ;; 隐藏项
  (call-with-output-file (build-path dir ".hidden") #:exists 'replace (lambda (o) (display "x" o)))
  (define-values (_edh th) (tree-refresh ed5 t5))
  (check-false (for/or ([p (in-vector (tree-entries th))]) (equal? p (build-path dir ".hidden"))))
  (define-values (_edh2 th2) (tree-set-show-hidden ed5 th #t))
  (check-true (for/or ([p (in-vector (tree-entries th2))]) (equal? p (build-path dir ".hidden"))))

  ;; current 高亮：provider 给 tree-current face
  (define t9 (tree-set-current t  (build-path dir "a.txt")))
  (define eda (editor-view-goto ed1 (tree-view t9) (point 1 0)))  ; 第 1 行 = a.txt
  (check-equal? (tree-selected eda t9) (build-path dir "a.txt"))
  (check-equal? (caddr (car ((tree-provider eda t9) eda (tree-document-id t9) 1)))
                (hash 'face 'tree-current))

  ;; 投影能出帧
  (check-true (screen? (tree-screen ed1 t)))

  (delete-directory/files dir)
  (displayln "tree.rkt: all tests passed"))
