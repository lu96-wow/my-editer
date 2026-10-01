#lang racket

;;; ============================================================================
;;; tree-model.rkt —— 文件树的数据模型
;;; ============================================================================
;;;
;;; 纯数据 + 纯变换：目录树、展开状态、children 缓存、提示行数据、可见节点、
;;; 行 ↔ 节点映射。不碰 document、不碰输入、不碰投影。
;;;
;;; 「一行一项」这条规则在这里定死：`visible-of` 的第 i 项 ↔ 文档第 i 行。

(require "tree-files.rkt"
         "fs.rkt")

(provide (struct-out tree)
         (struct-out prompt)
         tree-open
         visible-of
         tree-structure-lines
         tree-lines
         tree-struct-face
         tree-line-entry
         tree-line-of
         structure-count
         tree-toggle!
         tree-refresh-dir
         tree-target-dir
         ;; 提示行（数据层）
         prompt-line
         tree-set-prompt
         tree-clear-prompt
         tree-set-prompt-value
         tree-prompt-active?
         tree-set-goto)

;;; ---------- 数据 ----------

(struct tree (root expanded children prompt mode goto) #:transparent)
;; root     : entry（目录；name 是绝对路径）
;; expanded : hash（dir-path → #t）
;; children : hash（dir-path → (listof entry)）
;; prompt   : #f | (prompt kind label value data)
;; mode     : 'files | 'views
;; goto     : #f | path —— 投影后光标落到的行（建/删后定位；投影时消费掉）

(struct prompt (kind label value data) #:transparent)
;; kind : 'file | 'dir | 'delete
;; label: string（输入行里只读的前缀）
;; value: string（用户已输入部分）
;; data : file/dir → 目标目录 path；delete → 目标 path

;;; ---------- 构造 ----------

(define (tree-open root)
  (define r (canon-path (if (path? root) root (string->path root))))
  (define re (entry (path->string r) r (directory-exists? r)))
  (tree re
        (if (directory-exists? r) (hash r #t) (hash))
        (if (directory-exists? r) (hash r (list-dir r)) (hash))
        #f
        'files
        #f))

;;; ---------- 可见节点（一行一项） ----------

(define (visible-of t)
  (define (walk e d)
    (cons (cons d e)
          (if (and (entry-dir? e) (hash-has-key? (tree-expanded t) (entry-path e)))
              (append* (for/list ([k (in-list (hash-ref (tree-children t) (entry-path e) '()))])
                         (walk k (add1 d))))
              '())))
  (walk (tree-root t) 0))

;; 一行结构文本：前导空格**只表示层次**（每层 2 格）。
;; 根目录与它的一级子项同列（不缩进）：根是标题、一级子项是顶层，靠颜色区分；
;; 从二级起用 2 空格/层表示层次。
(define (structure-line d.e)
  (define e (cdr d.e))
  (string-append (make-string (* 2 (max 0 (sub1 (car d.e)))) #\space) (entry-name e)))

(define (tree-structure-lines t)
  (for/list ([d.e (in-list (visible-of t))]) (structure-line d.e)))

;; 文件模式结构行（对外名）。
(define (tree-lines t) (tree-structure-lines t))

;; 一行的 face：文件夹 / 已打开文件 / 未打开文件。
(define (line-face opened e)
  (cond [(entry-dir? e) 'tree-dir]
        [(hash-has-key? opened (entry-path e)) 'tree-open]
        [else 'tree-file]))

;; 结构行的 face：根目录单独用一个 face（橙色），其余按类型。
(define (tree-struct-face opened d.e)
  (if (zero? (car d.e)) 'tree-root (line-face opened (cdr d.e))))

(define (tree-line-entry st line)
  (define vis (visible-of st))
  (and (>= line 0) (< line (length vis)) (cdr (list-ref vis line))))

(define (tree-line-of st path)
  (for/first ([v (in-list (visible-of st))] [i (in-naturals)]
              #:when (equal? (entry-path (cdr v)) path)) i))

(define (structure-count st) (length (visible-of st)))

;;; ---------- 展开 / 刷新 / 落点 ----------

(define (tree-toggle! st e)
  (define dir (entry-path e))
  (cond
    [(not (entry-dir? e)) st]
    [(hash-has-key? (tree-expanded st) dir)
     (struct-copy tree st [expanded (hash-remove (tree-expanded st) dir)])]
    [else
     (define children (hash-set (tree-children st) dir
                                (or (hash-ref (tree-children st) dir #f) (list-dir dir))))
     (struct-copy tree st [children children]
                  [expanded (hash-set (tree-expanded st) dir #t)])]))

(define (tree-refresh-dir st dir)
  (struct-copy tree st [children (hash-set (tree-children st) dir (list-dir dir))]))

;; 新建落点：目录 → 本身；文件 → 父目录；无 entry（输入行 / 越界）→ root。
(define (tree-target-dir st line)
  (define e (tree-line-entry st line))
  (define root (entry-path (tree-root st)))
  (cond
    [(not e) root]
    [(entry-dir? e) (entry-path e)]
    [else (parent-path (entry-path e))]))

;;; ---------- 提示行（数据层） ----------

(define (tree-prompt-active? st) (and (tree-prompt st) #t))

(define (tree-set-prompt st kind label data)
  (struct-copy tree st [prompt (prompt kind label "" data)] [goto #f]))

(define (tree-clear-prompt st) (struct-copy tree st [prompt #f]))

(define (tree-set-prompt-value st v)
  (struct-copy tree st [prompt (struct-copy prompt (tree-prompt st) [value v])]))

;; 输入行文本（label ⊕ value）；没有提示 → #f。
(define (prompt-line st)
  (define p (tree-prompt st))
  (and p (string-append (prompt-label p) (prompt-value p))))

(define (tree-set-goto st path) (struct-copy tree st [goto path]))
