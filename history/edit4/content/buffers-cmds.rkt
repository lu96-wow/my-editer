#lang racket

;;; edit4/content/buffers-cmds.rkt —— 文档管理面板（buffers）命令
;;;
;;; 选择行来自面板文档的光标行（一切皆 document）。命令只改 content 或产出
;;; 新 World / effect；close-doc 走 prompt（脏则先问）。

(provide buffers-commands)

(require racket/list
         "../core/world.rkt" "../core/command.rkt"
         "model.rkt" "adapter.rkt" "buffers.rkt" "lifecycle.rkt" "prompt.rkt"
         "placing.rkt")

(define (buffers-vid w)
  (define c (world-content w))
  (and c (content-panel-vid c "*buffers*")))

(define (buffers-current w)
  (define c (world-content w))
  (define v (buffers-vid w))
  (define rows (buffer-rows w))
  (cond
    [(not (and c v)) #f]
    [else
     (define i (view-line (content-ed c) v))
     (and (pair? rows) (< i (length rows)) (list-ref rows i))]))

(define (set-fold w did v)
  (define c (world-content w))
  (define f (content-fold c))
  (world-set-content w (content-set-fold c (if v (hash-set f did #t) (hash-remove f did)))))

(define (h-buffers-enter ctx w args)
  (define cur (buffers-current w))
  (cond
    [(not cur) #f]
    [(eq? (list-ref cur 4) 'view) (cons (reveal-or-place! w (cadr cur)) '())]
    [else (cons (reveal-or-place-doc! w (car cur)) '())]))

(define (h-buffers-expand ctx w args)
  (define cur (buffers-current w))
  (cond [(not cur) #f] [else (cons (set-fold w (car cur) #f) '())]))

(define (h-buffers-collapse ctx w args)
  (define cur (buffers-current w))
  (cond [(not cur) #f] [else (cons (set-fold w (car cur) #t) '())]))

(define (h-buffers-toggle ctx w args)
  (define cur (buffers-current w))
  (cond
    [(not cur) #f]
    [else (define did (car cur))
          (define c (world-content w))
          (cons (set-fold w did (not (hash-has-key? (content-fold c) did))) '())]))

;; 新建视图：当前行文档（或焦点文档）再加一个视图（C-n）。
(define (h-new-view ctx w args)
  (define cur (buffers-current w))
  (define did (if cur (car cur) (focused-did w)))
  (define c (world-content w))
  (cond
    [(not did) #f]
    [else (define-values (c* _vid) (content-add-view! c did 60 22))
          (cons (world-set-content w c*) '())]))

;; C-d：视图行 → 关掉该视图（窗口）；文档行 → 走统一的关闭流程（脏则询问）。
(define (h-buffers-close ctx w args)
  (define cur (buffers-current w))
  (define c (world-content w))
  (cond
    [(not (and cur c)) #f]
    [(eq? (list-ref cur 4) 'view)
     (cons (ensure-focus (world-set-content w (content-remove-vid c (cadr cur)))) '())]
    [else (call-with-values (lambda () (request-close-doc* w (car cur))) cons)]))

(define buffers-commands
  (make-command-registry
   (list (cons 'buffers-enter h-buffers-enter)
         (cons 'buffers-expand h-buffers-expand)
         (cons 'buffers-collapse h-buffers-collapse)
         (cons 'buffers-toggle h-buffers-toggle)
         (cons 'new-view h-new-view)
         (cons 'buffers-close h-buffers-close))))
