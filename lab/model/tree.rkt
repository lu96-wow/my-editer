#lang racket

;;; lab/model/tree.rkt —— 两棵树（文件树 / 文档管理树），**各自是一个 document**
;;;
;;; 树 = 普通 core document：文本是「缩进 + 标记 + 名字」一行的列表，颜色来自高亮轨，
;;; 整篇只读。因此它们天然复用 core 的光标 / 滚动 / 渲染；树特有的转发与命令走本模块。
;;;
;;;   tree  = kind ⊕ vid ⊕ root(tnode)
;;;   tnode = name ⊕ id ⊕ kind ⊕ depth ⊕ expanded? ⊕ children
;;;     · 文件树  id = 路径字符串；kind = 'dir / 'file；children 懒加载（展开时读盘）
;;;     · 文档树  id = did / vid；kind = 'doc / 'view；children 内存构造
;;;
;;; 两棵树在 editor 里就是两个 document + 两个 view（sidebar-vids），不搞特殊面板。

(require racket/list racket/path racket/file
         "session.rkt"
         "../protocol.rkt"
         "../../core/editor.rkt"
         "../../core/text/document.rkt")

(provide
 (struct-out tnode)
 (struct-out tree)

 ;; 装配 / 刷新
 trees-init
 trees-refresh
 tree-reload!

 ;; 查询
 tree-of-view active-tree
 tree-visible tree-rows tree-node-at-line tree-current-node
 tree-vid sidebar-switch!

 ;; 操作（返回 session / (values session effects)）
 tree-toggle! tree-activate! tree-close! tree-create! tree-delete!
 focus-document-first-view)

;;; ---------- 数据 ----------

(struct tnode (name id kind depth expanded? children) #:transparent)
(struct tree (kind vid root) #:transparent)

;;; ---------- 装配 ----------

(define default-view-width 80)
(define default-view-height 24)

;; 在 session 上追加两个树文档 + 两个树视图，并生成内容。
(define (trees-init s)
  (define project (or (session-project s) (current-directory)))
  (define ed (session-editor s))
  (define-values (ed1 did1 vid1)
    (editor-add-document-view ed "" default-view-width default-view-height "files"))
  (define-values (ed2 did2 vid2)
    (editor-add-document-view ed1 "" default-view-width default-view-height "documents"))
  (session-normalize-focus
   (trees-refresh
    (struct-copy session s
      [editor ed2]
      [docs (hash-set (hash-set (session-docs s) did1 (doc-meta #f))
                      did2 (doc-meta #f))]
      [project project]
      [tree-vids (list vid1 vid2)]
      [sidebar-kind 'files]))))

;; 刷两棵树：文件树保留模型，文档树从当前 documents 重建；然后重画两篇文档。
(define (trees-refresh s)
  (define old (session-trees s))
  (define vids (session-tree-vids s))
  (cond
    [(or (null? vids) (null? (cdr vids))) s]
    [else
     (define ft (or (findf (lambda (t) (eq? (tree-kind t) 'files)) old)
                    (tree 'files (car vids)
                          (make-fs-root (or (session-project s) (current-directory))))))
     (define dt0 (findf (lambda (t) (eq? (tree-kind t) 'documents)) old))
     (define dt (tree 'documents (cadr vids) (build-doc-root s)))
     (define dt* (if dt0 (tree-copy-expanded dt0 dt) dt))
     (define s* (struct-copy session s [trees (list ft dt*)]))
     (assign-tree! s* ft)
     (assign-tree! s* dt*)
     s*]))

;; 重读所有展开目录（建 / 删之后用），再刷新。
(define (tree-reload! s)
  (define ts* (for/list ([t (in-list (session-trees s))])
                (if (eq? (tree-kind t) 'files)
                    (struct-copy tree t [root (reload-expanded (tree-root t))])
                    t)))
  (trees-refresh (struct-copy session s [trees ts*])))

;;; ---------- 查询 ----------

(define (tree-of-view s vid)
  (findf (lambda (t) (equal? (tree-vid t) vid)) (session-trees s)))

(define (active-tree s)
  (define a (session-active s))
  (and a (tree-of-view s a)))

;; 切换侧栏显示哪棵树（files ↔ documents），并把焦点移到它。
(define (sidebar-switch! s)
  (define vids (session-tree-vids s))
  (cond
    [(or (null? vids) (null? (cdr vids))) s]
    [else
     (define k (if (eq? (session-sidebar-kind s) 'files) 'documents 'files))
     (define v (if (eq? k 'files) (car vids) (cadr vids)))
     (session-focus
      (struct-copy session s [sidebar-kind k] [sidebar-hidden? #f])
      v)]))

(define (tree-visible t) (node-visible (tree-root t)))
(define (tree-rows t) (tree-visible t))

(define (tree-node-at-line t line)
  (define rows (tree-visible t))
  (and (>= line 0) (< line (length rows)) (list-ref rows line)))

(define (tree-current-node s)
  (define t (active-tree s))
  (and t (tree-node-at-line t (editor-view-point-line (session-editor s) (tree-vid t)))))

;;; ---------- 文档生成（文本 + 颜色 + 只读） ----------

(define (assign-tree! s t)
  (editor-view-assign! (session-editor s) (tree-vid t) (tree->document s t))
  (void))

(define (tree->document s t)
  (define rows (tree-visible t))
  (define lines (for/list ([n (in-list rows)]) (row-text n)))
  (define text (string-join lines "\n"))
  (define doc0 (document-open text))
  (define hl (for/list ([n (in-list rows)] [l (in-list lines)] [i (in-naturals)])
               (list i 0 i (string-length l) (row-face s t n))))
  (define doc1 (document-highlight-fill-batch doc0 hl))
  (define ro (for/list ([l (in-list lines)] [i (in-naturals)])
               (list i 0 i (string-length l) #t)))
  (document-readonly-fill-batch doc1 ro))

;; 一行 = 纯缩进（2 格/层）+ 名字；类型由颜色区分，不再加标记/对齐。
(define (row-text n)
  (string-append (make-string (* 2 (tnode-depth n)) #\space)
                 (tnode-name n)))

(define (row-face s t n)
  (case (tnode-kind n)
    [(dir root) 'tree-dir]
    [(file) (if (document-open-by-path? s (tnode-id n)) 'tree-open 'tree-file)]
    [(doc) 'tree-doc]
    [(view) (if (equal? (tnode-id n) (session-active s)) 'tree-view-active 'tree-view)]
    [else #f]))

(define (document-open-by-path? s path)
  (for/or ([did (in-hash-keys (session-docs s))])
    (equal? (doc-meta-path (hash-ref (session-docs s) did)) path)))

;;; ---------- 文件系统（本模块唯一碰盘的地方） ----------

(define (fs-exists? p) (or (file-exists? p) (directory-exists? p)))
(define (fs-dir? p) (directory-exists? p))
(define (fs-name p)
  (define parts (explode-path p))
  (if (null? parts) (path->string p) (path->string (last parts))))

;; 目录在前、文件在后，各自按名字排序。
(define (fs-list dir)
  (define entries
    (for/list ([e (in-list (directory-list dir))])
      (build-path dir (file-name-from-path e))))
  (define dirs (sort (filter directory-exists? entries) string<? #:key path->string))
  (define files (sort (filter file-exists? entries) string<? #:key path->string))
  (append dirs files))

(define (fs-create-file p)
  (when (fs-exists? p) (error 'fs-create-file "已存在: ~a" p))
  (display-to-file "" p #:exists 'error)
  p)

(define (fs-create-dir p)
  (when (fs-exists? p) (error 'fs-create-dir "已存在: ~a" p))
  (make-directory p)
  p)

(define (fs-delete p)
  (cond [(directory-exists? p) (delete-directory/files p)]
        [(file-exists? p) (delete-file p)]
        [else (error 'fs-delete "不存在: ~a" p)]))

;;; ---------- 文件树节点 ----------

(define (fs-node path depth)
  (define d? (fs-dir? path))
  (tnode (fs-name path) (path->string path)
         (if d? 'dir 'file) depth #f
         (if d? #f '())))

(define (load-children n)
  (cond
    [(not (eq? (tnode-kind n) 'dir)) n]
    [(tnode-children n) n]
    [else (struct-copy tnode n
            [children (for/list ([p (in-list (fs-list (tnode-id n)))])
                        (fs-node p (add1 (tnode-depth n))))])]))

(define (make-fs-root dir)
  (struct-copy tnode (load-children (fs-node dir 0)) [expanded? #t]))

(define (node-visible n)
  (define n* (if (and (eq? (tnode-kind n) 'dir) (tnode-expanded? n)) (load-children n) n))
  (cons n*
        (if (and (tnode-expanded? n*) (pair? (tnode-children n*)))
            (append* (for/list ([c (in-list (tnode-children n*))]) (node-visible c)))
            '())))

;; 重读所有展开目录的子节点。
(define (reload-expanded n)
  (cond
    [(and (eq? (tnode-kind n) 'dir) (tnode-expanded? n))
     (define n* (struct-copy tnode n
                  [children (for/list ([p (in-list (fs-list (tnode-id n)))])
                              (fs-node p (add1 (tnode-depth n))))]))
     (struct-copy tnode n* [children (map reload-expanded (tnode-children n*))])]
    [else n]))

;;; ---------- 文档树节点 ----------

(define (build-doc-root s)
  (define ed (session-editor s))
  (define tree-dids
    (for/list ([v (in-list (session-tree-vids s))])
      (editor-view-document-id ed v)))
  (define children
    (for/list ([e (in-list (editor-documents ed))]
               #:unless (member (document-entry-id e) tree-dids))
      (define did (document-entry-id e))
      (define views (for/list ([v (in-list (editor-views ed))] #:when (= did (view-did v))) v))
      (tnode (document-entry-name e) did 'doc 1 #t
             (for/list ([v (in-list views)])
               (tnode (format "view ~a" (view-id v)) (view-id v) 'view 2 #f '())))))
  (tnode "documents" 'root 'root 0 #t children))

;;; ---------- 展开状态搬运 ----------

(define (tree-copy-expanded old new)
  (struct-copy tree new [root (copy-exp (tree-root old) (tree-root new))]))

(define (copy-exp o n)
  (define o* (find-node o (tnode-id n)))
  (struct-copy tnode n
    [expanded? (cond [(and o* (eq? (tnode-kind n) 'dir)) (tnode-expanded? o*)]
                     [else (tnode-expanded? n)])]
    [children (and (tnode-children n) (map (lambda (c) (copy-exp o c)) (tnode-children n)))]))

(define (find-node n id)
  (cond [(equal? (tnode-id n) id) n]
        [else (for/or ([c (in-list (or (tnode-children n) '()))]) (find-node c id))]))

(define (update-node n id f)
  (cond
    [(equal? (tnode-id n) id) (f n)]
    [else (struct-copy tnode n
            [children (and (tnode-children n)
                           (map (lambda (c) (update-node c id f)) (tnode-children n)))])]))

(define (subst-tree ts t t*)
  (for/list ([x (in-list ts)]) (if (eq? x t) t* x)))

;;; ---------- 操作 ----------

(define (tree-toggle! s)
  (define t (active-tree s))
  (define n (tree-current-node s))
  (cond
    [(or (not t) (not n)) s]
    [else
     (define t* (struct-copy tree t
                  [root (update-node (tree-root t) (tnode-id n)
                          (lambda (x)
                            (cond [(not (eq? (tnode-kind x) 'dir)) x]
                                  [else (struct-copy tnode (load-children x)
                                          [expanded? (not (tnode-expanded? x))])])))]))
     (trees-refresh (struct-copy session s [trees (subst-tree (session-trees s) t t*)]))]))

(define (tree-activate! s)
  (define t (active-tree s))
  (define n (and t (tree-current-node s)))
  (cond
    [(not n) (values s '())]
    [(eq? (tree-kind t) 'files)
     (case (tnode-kind n)
       [(dir) (values (tree-toggle! s) '())]
       [(file) (define did (document-id-by-path s (tnode-id n)))
               (if did
                   (values (focus-document-first-view s did) '())
                   (values s (list (io-load (tnode-id n)))))]
       [else (values s '())])]
    [(eq? (tree-kind t) 'documents)
     (case (tnode-kind n)
       [(doc) (values (focus-document-first-view s (tnode-id n)) '())]
       [(view) (values (session-focus s (tnode-id n)) '())]
       [else (values s '())])]
    [else (values s '())]))

(define (tree-close! s)
  (define t (active-tree s))
  (define n (and t (tree-current-node s)))
  (cond
    [(not n) s]
    [(eq? (tree-kind t) 'files)
     (case (tnode-kind n)
       [(dir) (tree-toggle! s)]                       ; 目录 → 折叠
       [(file) (define did (document-id-by-path s (tnode-id n)))
               (if did (trees-refresh (session-close-document s did)) s)]
       [else s])]
    [(eq? (tree-kind t) 'documents)
     (case (tnode-kind n)
       [(view) (trees-refresh (session-close-view s (tnode-id n)))]
       [(doc) (trees-refresh (session-close-document s (tnode-id n)))]
       [else s])]
    [else s]))

;; 建文件 / 文件夹：弹输入行，回车后在「当前节点所在目录」创建。
(define (tree-create! s what)
  (define dir (current-dir s))
  (session-set-prompt s
    (prompt (format "new ~a: " (if (eq? what 'file) "file" "dir")) ""
            (lambda (s* name)
              (cond
                [(string=? name "") s*]
                [else
                 (define path (build-path dir name))
                 (case what
                   [(file) (fs-create-file path)]
                   [(dir) (fs-create-dir path)])
                 (tree-reload! s*)])))))

;; 删除当前文件 / 文件夹：弹确认（y/n）；已打开的对应文档一并关掉。
(define (tree-delete! s)
  (define n (tree-current-node s))
  (cond
    [(or (not n) (member (tnode-kind n) '(root doc view))) s]
    [else
     (define id (tnode-id n))
     (session-set-prompt s
       (prompt (format "delete ~a? (y/n): " (tnode-name n)) ""
               (lambda (s* ans)
                 (if (string=? (string-downcase ans) "y")
                     (let* ([s1 (close-docs-under s* id)])   ; 先关幽灵文档
                       (fs-delete id)
                       (tree-reload! s1))
                     s*))))]))

;;; ---------- 杂 ----------

(define (document-id-by-path s path)
  (for/first ([did (in-hash-keys (session-docs s))]
              #:when (equal? (doc-meta-path (hash-ref (session-docs s) did)) path))
    did))

;; 关掉路径等于 path 或位于 path 目录下的所有文档（删文件/删目录时用）。
(define (close-docs-under s path)
  (define base (regexp-replace #rx"/+$" path ""))
  (define prefix (string-append base "/"))
  (define dids
    (for/list ([did (in-hash-keys (session-docs s))]
               #:when (let ([p (doc-meta-path (hash-ref (session-docs s) did))])
                        (and p (or (string=? p base) (string-prefix? p prefix)))))
      did))
  (for/fold ([s s]) ([did (in-list dids)]) (session-close-document s did)))

(define (focus-document-first-view s did)
  (define v (for/first ([v (in-list (editor-views (session-editor s)))]
                        #:when (= did (view-did v)))
              v))
  (cond
    [v (session-focus s (view-id v))]
    [else (let-values ([(s* _vid) (session-new-view s did)]) s*)]))

;; 当前节点所在目录（文件 → 父目录；目录 → 自身；其它 → project）。
(define (current-dir s)
  (define t (active-tree s))
  (define n (and t (tree-current-node s)))
  (cond
    [(and n (eq? (tree-kind t) 'files) (eq? (tnode-kind n) 'dir)) (tnode-id n)]
    [(and n (eq? (tree-kind t) 'files) (eq? (tnode-kind n) 'file))
     (path->string (let-values ([(base _name _dir?) (split-path (tnode-id n))]) base))]
    [else (or (session-project s) (current-directory))]))
