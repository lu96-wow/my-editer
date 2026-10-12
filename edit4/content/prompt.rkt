#lang racket

;;; edit4/content/prompt.rkt —— 输入行（*input* 面板）+ kind → handler
;;;
;;; 输入行就是 *input* 面板文档：答案 = 该视图文本去掉 label 前缀。
;;; 打开 = 把状态栏窗口的 vid 临时换成 *input* 并聚焦；提交 / 取消 = 换回并回焦。
;;; kind → handler 是内容域的小注册表；handler : World prompt text -> (values World effects)。
;;;
;;; 这里同时放需要 prompt 的资源流程：退出（有脏文档先问）、关文档（脏先问）。

(provide prompt-open prompt-close prompt-submit prompt-cancel
         request-quit request-close-doc
         prompt-commands)

(require racket/list racket/string racket/path
         "../core/world.rkt" "../core/command.rkt" "../core/effect.rkt"
         "../layout/tree.rkt"
         "model.rkt" "adapter.rkt" "lifecycle.rkt")

(define input-name "*input*")

(define (panel-vid-of w name)
  (define c (world-content w))
  (and c (content-panel-vid c name)))

(define (window-of-vid w vid)
  (define c (world-content w))
  (and c vid
       (for/first ([id (in-list (ids (world-layout w)))]
                   #:when (eqv? (content-vid-of c id) vid))
         id)))

(define (prompt-of w)
  (define c (world-content w))
  (and c (content-prompt c)))

;;; ---------- 打开 / 关闭 ----------

(define (prompt-open w label kind data)
  (define c (world-content w))
  (define iv (panel-vid-of w input-name))
  (define sv (panel-vid-of w "*status*"))
  (define sw (window-of-vid w sv))
  (cond
    [(or (not c) (not iv) (not sw)) w]
    [else
     (define ed (content-ed c))
     (assign! ed iv label)
     (set-point! ed iv 0 (string-length label))
     (define did (view-did ed iv))
     (face-line! ed did 0 'input)
     (readonly-range! ed did 0 0 0 (string-length label) #t)
     (define w1 (world-set-content w (content-set-prompt c (prompt sw label kind data (world-focus w)))))
     (define w2 (world-set-focus w1 sw))
     (world-set-content w2 (content-bind (world-content w2) sw iv))]))

(define (prompt-close w)
  (define c (world-content w))
  (define p (and c (content-prompt c)))
  (cond
    [(not (and c p)) w]
    [else
     (define sw (prompt-wid p))
     (define sv (panel-vid-of w "*status*"))
     (define w1 (world-set-content w (content-set-prompt c #f)))
     (define w2 (if (and sw sv)
                    (world-set-content w1 (content-bind (world-content w1) sw sv))
                    w1))
     (define prev (prompt-prev-focus p))
     (world-set-focus w2 (if (and prev (has-id? w2 prev)) prev (world-focus w2)))]))

(define (prompt-answer w p)
  (define c (world-content w))
  (define iv (panel-vid-of w input-name))
  (define full (if iv (view-string (content-ed c) iv) ""))
  (define label (prompt-label p))
  (if (>= (string-length full) (string-length label))
      (string-trim (substring full (string-length label)))
      ""))

;;; ---------- kind → handler（内容域小注册表） ----------

(define (kind-close-doc w p text)
  (define did (car (prompt-data p)))
  (define ans (string-downcase text))
  (cond
    [(member ans '("y" "yes"))
     (define-values (w* effs ok?) (save-doc w did))
     (if ok?
         (values (close-doc! w* did) effs)
         (values (prompt-open w (prompt-label p) 'close-doc (prompt-data p)) '()))]
    [(member ans '("n" "no")) (values (close-doc! w did) '())]
    [else (values (prompt-open w (prompt-label p) 'close-doc (prompt-data p)) '())]))

(define (ask-quit w ds)
  (cond
    [(null? ds) (values w (list (quit-effect)))]
    [else (values (prompt-open w (format "save ~a? (y/n/all/nall) " (doc-display w (car ds)))
                              'quit ds)
                  '())]))

(define (kind-quit w p text)
  (define ds (prompt-data p))
  (define ans (string-downcase text))
  (define did (car ds))
  (define rest (cdr ds))
  (cond
    [(member ans '("y" "yes"))
     (define-values (w* effs ok?) (save-doc w did))
     (if ok?
         (call-with-values (lambda () (ask-quit w* rest))
           (lambda (w2 e2) (values w2 (append effs e2))))
         (values w (list (quit-effect))))]
    [(member ans '("n" "no")) (ask-quit w rest)]
    [(member ans '("all" "a"))
     (define-values (w* effs) (save-docs w (cons did rest)))
     (values w* (append effs (list (quit-effect))))]
    [(member ans '("nall" "none" "!")) (values w (list (quit-effect)))]
    [else (ask-quit w ds)]))

(define (kind-new-file w p text)
  (define d (car (prompt-data p)))
  (define nm (string-trim text))
  (cond [(string=? nm "") (values w '())]
        [else (values w (list (make-file (build-path d nm)) (reload-tree)))]))

(define (kind-new-dir w p text)
  (define d (car (prompt-data p)))
  (define nm (string-trim text))
  (cond [(string=? nm "") (values w '())]
        [else (values w (list (make-dir (build-path d nm)) (reload-tree)))]))

(define (kind-delete w p text)
  (define ans (string-downcase text))
  (cond [(member ans '("y" "yes"))
         (values w (list (delete-path (car (prompt-data p))) (reload-tree)))]
        [else (values w '())]))

(define prompt-kinds
  (hash 'close-doc kind-close-doc
        'quit kind-quit
        'new-file kind-new-file
        'new-dir kind-new-dir
        'delete kind-delete))

;;; ---------- 提交流程 ----------

(define (prompt-submit w)
  (define p (prompt-of w))
  (cond
    [(not p) (values w '())]
    [else
     (define text (prompt-answer w p))
     (define h (hash-ref prompt-kinds (prompt-kind p) #f))
     (define w1 (prompt-close w))
     (if h (h w1 p text) (values w1 '()))]))

(define (prompt-cancel w)
  (cond [(prompt-of w) (values (prompt-close w) '())]
        [else (values w '())]))

;;; ---------- 需要 prompt 的资源流程 ----------

(define (request-quit w)
  (define c (world-content w))
  (cond
    [(not c) (values w (list (quit-effect)))]
    [else (ask-quit w (dirty-dids c))]))

(define (focused-did w)
  (define c (world-content w))
  (define v (and c (content-vid-of c (world-focus w))))
  (and v (content-did-of c v)))

(define (request-close-doc w)
  (define c (world-content w))
  (define did (focused-did w))
  (cond
    [(not did) (values w '())]
    [(doc-dirty? c did)
     (values (prompt-open w (format "save ~a? (y/n) " (doc-display w did)) 'close-doc (list did)) '())]
    [else (values (close-doc! w did) '())]))

;;; ---------- 命令 ----------

(define (as-result thunk) (call-with-values thunk cons))

(define (h-prompt-submit ctx w args) (as-result (lambda () (prompt-submit w))))
(define (h-prompt-cancel ctx w args) (as-result (lambda () (prompt-cancel w))))
(define (h-quit ctx w args) (as-result (lambda () (request-quit w))))
(define (h-close-doc ctx w args) (as-result (lambda () (request-close-doc w))))

(define prompt-commands
  (make-command-registry
   (list (cons 'prompt-submit h-prompt-submit)
         (cons 'prompt-cancel h-prompt-cancel)
         (cons 'quit h-quit)
         (cons 'close-doc h-close-doc))))
