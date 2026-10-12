#lang racket

;;; edit4/content/tree.rkt —— 文件树（模型 + IO）
;;;
;;; 树状态挂在 content.tree 上（World 的类型化切片），不属于 view，也不再是 features hash。
;;; 读目录（IO）只在这里，且在 boot / reload 时调用，不在每帧投影里。
;;; 这里只产出结构化的「行」；把它渲染成文本是 view/tree.rkt 的事。

(provide (struct-out tree) tree-init refresh-tree! tree-rows)

(require racket/list racket/path
         "../core/world.rkt"
         "model.rkt" "fs.rkt")

;; root     : 绝对路径
;; expanded : dir -> #t（展开的目录）
;; children : dir -> (listof (cons path dir?))   目录快照缓存
(struct tree (root expanded children) #:transparent)

(define (tree-init root) (tree (simplify-path (path->complete-path root)) (hash) (hash)))

;; IO：读目录快照到缓存（只补未缓存的目录）
(define (tree-ensure ts)
  (define dirs (cons (tree-root ts) (hash-keys (tree-expanded ts))))
  (define ch
    (for/fold ([ch (tree-children ts)]) ([d (in-list dirs)] #:unless (hash-has-key? ch d))
      (hash-set ch d (with-handlers ([exn:fail? (lambda (_) '())]) (fs-read-dir d)))))
  (struct-copy tree ts [children ch]))

;; IO：刷新树的目录缓存（boot / 重载时调用，不在每帧投影里）
(define (refresh-tree! w #:root [root (current-directory)])
  (define c (world-content w))
  (cond
    [(not c) w]
    [else
     (define ts (content-tree c))
     (world-set-content w (content-set-tree c (tree-ensure (if ts ts (tree-init root)))))]))

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
