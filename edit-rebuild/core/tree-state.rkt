#lang racket

;;; edit-rebuild/core/tree-state.rkt —— 目录导航 + 查询状态机（纯）
;;;
;;; 树状态 = root + 展开集 + 目录快照缓存 + 查询状态。
;;; **纯**：不 require 任何 I/O；读目录由调用方注入
;;;     read-dir : path -> (listof direntry)
;;; 失败处理先留空（由注入方决定；返回 '() 即视为空目录）。
;;;
;;; 导航：展开 / 收起 / 切换 / 刷新；`tree-rows` 把已展开部分摊平成可见行。
;;; 查询：按名字子串搜整棵子树；命中后**自动展开到根**（reveal），
;;;       可在匹配间 next / prev 跳转（环形）。

(require racket/path
         racket/list
         racket/string
         "path.rkt")

(provide
 ;; 值
 (struct-out direntry) (struct-out entry)
 (struct-out tree-state) (struct-out tree-search)
 ;; 构造 / 导航
 tree-state-open
 tree-expanded?
 tree-expand tree-collapse tree-toggle
 tree-reveal
 tree-refresh tree-refresh-dir tree-invalidate
 ;; 读
 tree-rows tree-row-index
 ;; 查询
 tree-search-set tree-search-next tree-search-prev tree-search-clear
 tree-search-current tree-search-match?
 tree-match?)

;;; ---------- 值 ----------

;; 目录项（read-dir 的产物）。name / hidden? 从 path 纯派生。
(struct direntry (path dir? link?) #:transparent)

(define (direntry-name d)
  (path->string (or (file-name-from-path (direntry-path d)) (direntry-path d))))
(define (direntry-hidden? d)
  (define nm (direntry-name d))
  (and (> (string-length nm) 0) (char=? (string-ref nm 0) #\.)))

;; 摊平后的可见行（渲染用）。
(struct entry (path name dir? link? hidden? depth) #:transparent)

;; 树状态。
(struct tree-state (root expanded children search) #:transparent)
;; root     : path                        规范化根
;; expanded : (hash path -> #t)           展开的目录
;; children : (hash path -> (listof direntry))  已读目录的快照（缓存）
;; search   : tree-search | #f

;; 查询状态。
(struct tree-search (text matches index) #:transparent)
;; text    : string
;; matches : (listof path)               命中的路径（顺序 = 子树 DFS）
;; index   : exact-nonnegative-integer | #f   当前命中的下标

;;; ---------- 路径工具（纯） ----------

;; root 到 p 的**父目录链**（含 root；不含 p 自身）；p 不在 root 下 → '()。
(define (ancestor-dirs root p)
  (define r (normalize root))
  (define np (normalize p))
  (cond
    [(or (equal? r np) (not (path-under? r np))) '()]
    [else
     (define parts (explode-path (find-relative-path r np)))
     (define dirs
       (for/list ([i (in-range 1 (add1 (length parts)))])
         (simplify-path (apply build-path r (take parts i)))))
     (cons r (drop-right dirs 1))]))

;;; ---------- 目录读取 + 排序（缓存入口） ----------

(define (sort-direntries ds)
  (sort ds (lambda (a b)
             (define da (direntry-dir? a))
             (define db (direntry-dir? b))
             (cond [(and da (not db)) #t]
                   [(and db (not da)) #f]
                   [else (string-ci<? (direntry-name a) (direntry-name b))]))))

;; 读一个目录并把快照放进缓存（已有则不重读）。
(define (ensure-children t p read-dir)
  (define np (normalize p))
  (cond
    [(hash-has-key? (tree-state-children t) np) t]
    [else (struct-copy tree-state t
            [children (hash-set (tree-state-children t) np
                                (sort-direntries (read-dir np)))])]))

;;; ---------- 构造 / 导航 ----------

(define (tree-state-open root read-dir)
  (define r (normalize root))
  (tree-state r
              (hash r #t)
              (hash r (sort-direntries (read-dir r)))
              #f))

(define (tree-expanded? t p)
  (and (hash-ref (tree-state-expanded t) (normalize p) #f) #t))

(define (tree-expand t p read-dir)
  (define np (normalize p))
  ;; 已展开也要保证缓存存在（invalidate 后需重读）。
  (define t1 (ensure-children t np read-dir))
  (cond
    [(tree-expanded? t1 np) t1]
    [else (struct-copy tree-state t1
            [expanded (hash-set (tree-state-expanded t1) np #t)])]))

(define (tree-collapse t p)
  (struct-copy tree-state t
    [expanded (hash-remove (tree-state-expanded t) (normalize p))]))

(define (tree-toggle t p read-dir)
  (if (tree-expanded? t p) (tree-collapse t p) (tree-expand t p read-dir)))

;; 展开 p 的所有祖先目录，使 p 成为可见行。
(define (tree-reveal t p read-dir)
  (for/fold ([t t]) ([d (in-list (ancestor-dirs (tree-state-root t) p))])
    (tree-expand t d read-dir)))

;; 重读所有已缓存目录（外部变更后刷新）。
(define (tree-refresh t read-dir)
  (for/fold ([t t]) ([p (in-list (hash-keys (tree-state-children t)))])
    (tree-refresh-dir t p read-dir)))

;; 重读一个目录（仅当它已在缓存里）；不在缓存则不动。
(define (tree-refresh-dir t p read-dir)
  (define np (normalize p))
  (cond
    [(hash-has-key? (tree-state-children t) np)
     (struct-copy tree-state t
       [children (hash-set (tree-state-children t) np
                           (sort-direntries (read-dir np)))])]
    [else t]))

;; 丢掉一个目录的缓存（下次访问 / 展开时重读）。
(define (tree-invalidate t p)
  (struct-copy tree-state t
    [children (hash-remove (tree-state-children t) (normalize p))]))

;;; ---------- 读：摊平 ----------

(define (entry-of d depth)
  (define p (direntry-path d))
  (entry p (direntry-name d) (direntry-dir? d) (direntry-link? d)
         (direntry-hidden? d) depth))

(define (root-entry root)
  (define nm (path->string (or (file-name-from-path root) root)))
  (entry root nm #t #f (and (> (string-length nm) 0) (char=? (string-ref nm 0) #\.)) 0))

;; 可见行 = root + 已展开目录的内容（DFS）。
(define (tree-rows t)
  (define root (tree-state-root t))
  (define (walk p depth)
    (define np (normalize p))
    (if (tree-expanded? t np)
        (append*
         (for/list ([d (in-list (hash-ref (tree-state-children t) np '()))])
           (cons (entry-of d depth)
                 (if (and (direntry-dir? d) (tree-expanded? t (direntry-path d)))
                     (walk (direntry-path d) (add1 depth))
                     '()))))
        '()))
  (cons (root-entry root) (walk root 1)))

;; p 在可见行里的下标；不可见 / 不在树里 → #f。
(define (tree-row-index t p)
  (define np (normalize p))
  (for/first ([e (in-list (tree-rows t))] [i (in-naturals)]
              #:when (equal? np (normalize (entry-path e))))
    i))

;;; ---------- 查询 ----------

(define (tree-match? text name)
  (string-contains? (string-downcase name) (string-downcase text)))

;; 整棵子树 DFS 收集命中项；顺带把读过的目录放进缓存。match? : entry -> boolean
(define (collect-matches t match? read-dir)
  (define (walk t p depth)
    (define np (normalize p))
    (define t1 (ensure-children t np read-dir))
    (for/fold ([t t1] [ms '()]) ([d (in-list (hash-ref (tree-state-children t1) np '()))])
      (define e (entry-of d depth))
      (define ms1 (if (match? e) (append ms (list (entry-path e))) ms))
      (cond
        [(direntry-dir? d)
         (define-values (t2 ms2) (walk t (direntry-path d) (add1 depth)))
         (values t2 (append ms1 ms2))]
        [else (values t ms1)])))
  (walk t (tree-state-root t) 1))

;; 设查询：搜整棵子树 → 展开所有命中的祖先（自动展开到根）→ 当前指向第一个。
;; match? 默认按名字子串；可传自定义（如只看文件）。
(define (tree-search-set t text read-dir [match? #f])
  (cond
    [(zero? (string-length text)) (struct-copy tree-state t [search #f])]
    [else
     (define pred (or match? (lambda (e) (tree-match? text (entry-name e)))))
     (define-values (t1 matches) (collect-matches t pred read-dir))
     (define t2 (for/fold ([t t1]) ([m (in-list matches)]) (tree-reveal t m read-dir)))
     (struct-copy tree-state t2
       [search (tree-search text matches (and (pair? matches) 0))])]))

(define (tree-search-current t)
  (define s (tree-state-search t))
  (and s (tree-search-index s)
       (list-ref (tree-search-matches s) (tree-search-index s))))

;; p 是否命中当前查询。
(define (tree-search-match? t p)
  (define s (tree-state-search t))
  (and s
       (let ([np (normalize p)])
         (for/or ([m (in-list (tree-search-matches s))]) (equal? np (normalize m))))))

(define (tree-search-step t read-dir dir)
  (define s (tree-state-search t))
  (cond
    [(or (not s) (null? (tree-search-matches s))) t]
    [else
     (define ms (tree-search-matches s))
     (define n (length ms))
     (define i (modulo (+ (or (tree-search-index s) 0) dir) n))
     (define t1 (tree-reveal t (list-ref ms i) read-dir))
     (struct-copy tree-state t1 [search (tree-search (tree-search-text s) ms i)])]))

(define (tree-search-next t read-dir) (tree-search-step t read-dir 1))
(define (tree-search-prev t read-dir) (tree-search-step t read-dir -1))

(define (tree-search-clear t)
  (struct-copy tree-state t [search #f]))
