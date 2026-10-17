#lang racket

;;; layer  : plugins/filetree
;;; effect : **IO** —— 读目录（directory-list / file-exists? / link-exists?）
;;;
;;; 文件树的唯一 IO 点。把“盘上有什么”压成有序条目列表：
;;;
;;;   dir-entries : path -> (listof (cons ('dir|'file) path))
;;;
;;; 排序约定：目录在前，同类按名字 (string-downcase) 升序。
;;; 读盘失败（权限 / 竞态）返回 '() 而不是抛异常：面板是观察者，不该打断编辑。
;;;
;;; 纯逻辑（行布局 / 缩进 / face）在 lines.rkt，它接收 dir-entries 作为参数，
;;; 所以可以喂假目录做纯测试。

(provide dir-entries
         filetree-normalize-path)

(require racket/path
         racket/list
         racket/string)

;; 绝对化 + 简化：树里所有 path 都用这个规范形式比较。
(define (filetree-normalize-path p)
  (path->string (simplify-path (path->complete-path p))))

(define (entry-kind path)
  (cond
    [(and (directory-exists? path) (not (link-exists? path))) 'dir]
    [(file-exists? path) 'file]
    [else #f]))

(define (name<? a b)
  (string<? (string-downcase (path->string (file-name-from-path a)))
            (string-downcase (path->string (file-name-from-path b)))))

(define (dir-entries path)
  (with-handlers ([exn:fail? (λ (_) '())])
    (define es
      (for/list ([n (in-list (directory-list path))])
        (define child (build-path path n))
        (define k (entry-kind child))
        (and k (cons k child))))
    (sort (filter values es)
          (λ (a b)
            (define ka (car a)) (define kb (car b))
            (cond [(and (eq? ka 'dir) (eq? kb 'file)) #t]
                  [(and (eq? ka 'file) (eq? kb 'dir)) #f]
                  [else (name<? (cdr a) (cdr b))])))))
