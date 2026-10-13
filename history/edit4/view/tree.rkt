#lang racket

;;; edit4/view/tree.rkt —— 文件树面板（纯投影）
;;;
;;; 只把 content/tree.rkt 的行结构渲染成文本 + faces；不读目录、不写引擎。
;;; 目录行末尾加 "/"；以 . 开头的是 hidden；已打开的文档染成 tree-open。

(provide tree-content)

(require racket/list
         "../core/world.rkt"
         "../content/model.rkt"
         "../content/tree.rkt")

(define (hidden-name? name)
  (and (positive? (string-length name)) (char=? #\. (string-ref name 0))))

(define (dir-label s)
  (if (or (zero? (string-length s)) (char=? #\/ (string-ref s (sub1 (string-length s)))))
      s
      (string-append s "/")))

(define (tree-content w v)
  (define c (world-content w))
  (define ts (and c (content-tree c)))
  (cond
    [(not ts) (values "" '())]
    [else
     (define rows (tree-rows ts))
     (define open-keys (map path-key (content-doc-paths c)))
     (define lines
       (for/list ([r (in-list rows)])
         (define name (list-ref r 1))
         (string-append (make-string (* 2 (list-ref r 3)) #\space)
                        (if (list-ref r 2) (dir-label name) name))))
     (values (string-join lines "\n")
             (for/list ([r (in-list rows)] [i (in-naturals)])
               (define p (car r))
               (define name (list-ref r 1))
               (define dir? (list-ref r 2))
               (cons i (cond
                         [(hidden-name? name) 'tree-hidden]
                         [(and (not dir?) (member (path-key p) open-keys)) 'tree-open]
                         [dir? 'tree-dir]
                         [else 'tree-file]))))]))
