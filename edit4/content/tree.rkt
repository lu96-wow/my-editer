#lang racket

;;; edit4/content/tree.rkt —— 文件树（模型 + IO）
;;;
;;; 树是**目录的缓存**（权威在文件系统），状态挂在 content.tree 上（World 的类型化切片）。
;;; 纯操作与 IO 分开：
;;;   · 纯操作（toggle/expand/parent/refresh/toggle-hidden/rows）：不碰盘；
;;;   · tree-ensure：读缺失/展开目录（IO），只在 boot / reload 时调用，不在每帧投影里。
;;; 这里只产出结构化的「行」；渲染成文本是 view/tree.rkt 的事。

(provide (struct-out tree) tree-init tree-ensure refresh-tree!
         tree-toggle-dir tree-expand-dir tree-parent-dir tree-refresh tree-toggle-hidden
         tree-rows)

(require racket/list racket/path
         "../core/world.rkt"
         "model.rkt" "fs.rkt")

;; root         : 绝对路径
;; expanded     : dir -> #t（展开的目录）
;; children     : dir -> (listof (cons path dir?))   目录快照缓存
;; show-hidden? : 是否显示 . 开头项
(struct tree (root expanded children show-hidden?) #:transparent)

(define (tree-init root) (tree (simplify-path (path->complete-path root)) (hash) (hash) #f))

;;; ---------- 纯操作 ----------

;; 清空目录快照缓存 → 下次 tree-ensure 重读磁盘（只影响树，不动已打开文档）。
(define (tree-refresh ts) (struct-copy tree ts [children (hash)]))

(define (tree-toggle-hidden ts)
  (struct-copy tree ts [show-hidden? (not (tree-show-hidden? ts))]))

(define (tree-toggle-dir ts dir)
  (struct-copy tree ts
               [expanded (if (hash-has-key? (tree-expanded ts) dir)
                             (hash-remove (tree-expanded ts) dir)
                             (hash-set (tree-expanded ts) dir #t))]))

(define (tree-expand-dir ts dir)
  (struct-copy tree ts [expanded (hash-set (tree-expanded ts) dir #t)]))

(define (tree-parent-dir p)
  (define d (path-only p))
  (and d (not (equal? (simplify-path d) (simplify-path p))) (simplify-path d)))

;;; ---------- IO ----------

;; 读缺失/展开目录到缓存（错误 → 当作空目录）。
(define (tree-ensure ts)
  (define dirs (cons (tree-root ts) (hash-keys (tree-expanded ts))))
  (define ch
    (for/fold ([ch (tree-children ts)]) ([d (in-list dirs)] #:unless (hash-has-key? ch d))
      (hash-set ch d (with-handlers ([exn:fail? (lambda (_) '())]) (fs-read-dir d)))))
  (struct-copy tree ts [children ch]))

;; 清缓存 + 重读（boot / reload 时调用）。
(define (refresh-tree! w #:root [root (current-directory)])
  (define c (world-content w))
  (cond
    [(not c) w]
    [else
     (define ts (content-tree c))
     (define ts* (tree-ensure (tree-refresh (if ts ts (tree-init root)))))
     (world-set-content w (content-set-tree c ts*))]))

;;; ---------- 行 ----------

(define (tree-hidden-path? p)
  (define n (path->string (file-name-from-path p)))
  (and (positive? (string-length n)) (char=? #\. (string-ref n 0))))

;; 可见行：(path name dir? depth)。顶部第一行是工作区根目录。
(define (tree-rows ts)
  (define show? (tree-show-hidden? ts))
  (define (walk dir depth)
    (append*
     (for/list ([e (in-list (hash-ref (tree-children ts) dir '()))]
                #:unless (and (not show?) (tree-hidden-path? (car e))))
       (define p (car e)) (define d? (cdr e))
       (cons (list p (path->string (file-name-from-path p)) d? depth)
             (if (and d? (hash-has-key? (tree-expanded ts) p)) (walk p (add1 depth)) '())))))
  (define root (tree-root ts))
  (cons (list root (path->string root) #t 0) (walk root 1)))
