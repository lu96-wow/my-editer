#lang racket

;;; edit-tui-rebuild/editor/resource.rkt —— 已打开文档的纯状态
;;;
;;; resource 记录“一个已打开文档”的身份 / 路径 / view / mode / 保存基线。
;;; 它不持有 engine 句柄；doc-id / view-id 仍是 id。
;;;
;;; 当前只做打开 / 去重 / mode / opened 集合；保存 / dirty UI 后续再补。

(require racket/path
         racket/string)

(provide (struct-out resource)
         (struct-out resources)
         empty-resources
         make-resource
         resources-add
         resources-list
         resources-find-path
         resources-find-doc
         resources-find-view
         resources-set-views
         resources-add-view
         resources-remove
         resources-set-saved-version
         resources-set-path
         resources-set-command-stack
         resources-opened-paths
         resource-normalize-path
         resource-display-path
         resource-dirty?)

(struct resource
  (id            ; resource id（当前 = doc-id）
   doc-id
   path          ; normalized absolute path string | #f
   name
   views         ; (listof view-id)
   mode          ; 'racket | 'text
   command-stack ; command-table-stack | #f：该 buffer 的键表
   saved-version)
  #:transparent)

(struct resources (items) #:transparent)

(define empty-resources (resources '()))

(define (make-resource id doc-id path name views mode saved-version
                       #:command-stack [command-stack #f])
  (resource id doc-id path name views mode command-stack saved-version))

(define (resources-add rs r)
  (resources (cons r (resources-items rs))))

(define (resources-list rs)
  (reverse (resources-items rs)))

(define (resources-find-path rs path)
  (and path
       (for/first ([r (in-list (resources-items rs))]
                   #:when (equal? (resource-path r) path))
         r)))

(define (resources-find-doc rs did)
  (for/first ([r (in-list (resources-items rs))]
              #:when (equal? (resource-doc-id r) did))
    r))

(define (resources-find-view rs vid)
  (for/first ([r (in-list (resources-items rs))]
              #:when (memv vid (resource-views r)))
    r))

(define (resources-add-view rs id vid)
  (define r (resources-find-doc rs id))
  (if (or (not r) (memv vid (resource-views r)))
      rs
      (resources-set-views rs id (append (resource-views r) (list vid)))))

(define (resources-remove rs id)
  (resources
   (for/list ([r (in-list (resources-items rs))]
              #:unless (equal? (resource-id r) id))
     r)))

(define (resources-set-views rs id views)
  (resources
   (for/list ([r (in-list (resources-items rs))])
     (if (equal? (resource-id r) id)
         (struct-copy resource r [views views])
         r))))

(define (resources-set-command-stack rs id command-stack)
  (resources
   (for/list ([r (in-list (resources-items rs))])
     (if (equal? (resource-id r) id)
         (struct-copy resource r [command-stack command-stack])
         r))))

(define (resources-set-path rs id path name mode)
  (resources
   (for/list ([r (in-list (resources-items rs))])
     (if (equal? (resource-id r) id)
         (struct-copy resource r [path path] [name name] [mode mode])
         r))))

(define (resources-set-saved-version rs id version)
  (resources
   (for/list ([r (in-list (resources-items rs))])
     (if (equal? (resource-id r) id)
         (struct-copy resource r [saved-version version])
         r))))

(define (resources-opened-paths rs)
  (for/fold ([h (hash)]) ([r (in-list (resources-items rs))])
    (if (resource-path r)
        (hash-set h (resource-path r) #t)
        h)))

(define (resource-normalize-path p)
  (path->string (simplify-path (path->complete-path p))))

;; 只用于显示：root 内 -> 相对路径；root 外 -> 绝对路径。
;; 路径数据本身仍然用绝对路径。
(define (resource-display-path root path)
  (define path* (resource-normalize-path path))
  (cond
    [(or (not root) (equal? root "")) path*]
    [else
     (define root* (resource-normalize-path root))
     (cond
       [(equal? root* path*) "."]
       [else
        (define rel (find-relative-path (string->path root*)
                                        (string->path path*)))
        (define rel-str (path->string rel))
        ;; find-relative-path 对根外路径也返回 ../...；这里按显示规则回退到绝对路径。
        (if (or (absolute-path? rel)
                (regexp-match? #rx"^\\.\\.[/\\\\]" rel-str))
            path*
            rel-str)])]))

(define (resource-dirty? r version)
  (and version (not (eq? version (resource-saved-version r)))))
