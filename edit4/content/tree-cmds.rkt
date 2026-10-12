#lang racket

;;; edit4/content/tree-cmds.rkt —— 文件树交互命令
;;;
;;; 命令只做两件事：改 content（折叠/展开/刷新/光标）或产出 effect（open 文件 / reload）。
;;; 选择行不另设游标：树面板就是 document，view-line 即当前行。

(provide tree-commands)

(require racket/list racket/path
         "../core/world.rkt" "../core/command.rkt" "../core/effect.rkt"
         "model.rkt" "adapter.rkt" "tree.rkt" "prompt.rkt")

(define (tree-vid w)
  (define c (world-content w))
  (and c (content-panel-vid c "*tree*")))

(define (tree-rows* w)
  (define c (world-content w))
  (define ts (and c (content-tree c)))
  (and ts (tree-rows ts)))

;; 当前选择行（面板视图光标所在行）→ (path name dir? depth) | #f
(define (tree-current w)
  (define c (world-content w))
  (define v (tree-vid w))
  (define rows (tree-rows* w))
  (cond
    [(not (and c v rows)) #f]
    [else
     (define i (view-line (content-ed c) v))
     (and (pair? rows) (< i (length rows)) (list-ref rows i))]))

;; 行的下标（按路径找）。
(define (tree-index w path)
  (define rows (tree-rows* w))
  (for/first ([r (in-list rows)] [i (in-naturals)]
              #:when (equal? (path-key path) (path-key (car r))))
    i))

(define (set-tree-line w i)
  (define c (world-content w))
  (define v (tree-vid w))
  (when (and c v) (set-point! (content-ed c) v i 0))
  w)

;;; ---------- 命令 ----------

;; enter：目录 → 展开/折叠并重读；文件 → open（effect）。
(define (h-tree-enter ctx w args)
  (define cur (tree-current w))
  (define c (world-content w))
  (cond
    [(not (and cur c)) #f]
    [(list-ref cur 2)
     (cons (world-set-content w (content-set-tree c (tree-toggle-dir (content-tree c) (car cur))))
           (list (reload-tree)))]
    [else (cons w (list (open-file (car cur))))]))

;; left：光标移到父目录行。
(define (h-tree-parent ctx w args)
  (define cur (tree-current w))
  (cond
    [(not cur) #f]
    [else
     (define pp (tree-parent-dir (car cur)))
     (cond
       [(not pp) #f]
       [else (define i (tree-index w pp))
             (if i (cons (set-tree-line w i) '()) #f)])]))

;; right：光标移到第一个子项（目录展开时）。
(define (h-tree-child ctx w args)
  (define cur (tree-current w))
  (define rows (tree-rows* w))
  (cond
    [(not (and cur rows (list-ref cur 2))) #f]
    [else
     (define i (tree-index w (car cur)))
     (cond
       [(and i (< (add1 i) (length rows))
             (= (list-ref (list-ref rows (add1 i)) 3) (add1 (list-ref cur 3))))
        (cons (set-tree-line w (add1 i)) '())]
       [else #f])]))

(define (h-tree-reload ctx w args) (cons w (list (reload-tree))))

;; 新建 / 删除的目标目录：当前行是目录则用它；是文件则用其父目录。
(define (tree-target-dir w)
  (define c (world-content w))
  (define ts (and c (content-tree c)))
  (define cur (tree-current w))
  (cond
    [(not ts) #f]
    [(not cur) (tree-root ts)]
    [(list-ref cur 2) (car cur)]
    [else (or (tree-parent-dir (car cur)) (tree-root ts))]))

(define (h-tree-new-file ctx w args)
  (define d (tree-target-dir w))
  (cond [(not d) #f]
        [else (cons (prompt-open w (format "新文件 ~a : " (path->string d)) 'new-file (list d)) '())]))

(define (h-tree-new-dir ctx w args)
  (define d (tree-target-dir w))
  (cond [(not d) #f]
        [else (cons (prompt-open w (format "新目录 ~a : " (path->string d)) 'new-dir (list d)) '())]))

(define (h-tree-delete ctx w args)
  (define cur (tree-current w))
  (cond [(not cur) #f]
        [else (cons (prompt-open w (format "删除 ~a ? (y/n) " (path->string (car cur)))
                                 'delete (list (car cur)))
                    '())]))

(define (h-tree-toggle-hidden ctx w args)
  (define c (world-content w))
  (define ts (and c (content-tree c)))
  (cond
    [(not (and c ts)) #f]
    [else (cons (world-set-content w (content-set-tree c (tree-toggle-hidden ts))) '())]))

(define tree-commands
  (make-command-registry
   (list (cons 'tree-enter h-tree-enter)
         (cons 'tree-parent h-tree-parent)
         (cons 'tree-child h-tree-child)
         (cons 'tree-reload h-tree-reload)
         (cons 'tree-new-file h-tree-new-file)
         (cons 'tree-new-dir h-tree-new-dir)
         (cons 'tree-delete h-tree-delete)
         (cons 'tree-toggle-hidden h-tree-toggle-hidden))))
