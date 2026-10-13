#lang racket

;;; edit4/content/prompt.rkt —— 输入行（*input* 面板）+ kind → handler
;;;
;;; 输入行就是 *input* 面板文档：答案 = 该视图文本去掉 label 前缀。
;;; 打开 = status dock（组合 (status input)）切到 *input* 成员并聚焦；关闭 = 切回 *status*。
;;; kind → handler 是内容域的小注册表；handler : World prompt text -> (values World effects)。
;;;
;;; 这里同时放需要 prompt 的资源流程：退出（有脏文档先问）、关文档（脏先问）。

(provide prompt-open prompt-close prompt-submit prompt-cancel
         request-quit request-close-doc request-close-doc*
         (struct-out prompt-kind-registry)
         make-prompt-kind-registry prompt-kind-register prompt-kind-lookup prompt-kind-merge
         base-prompt-kinds make-prompt-submit
         prompt-commands)

(require racket/list racket/string racket/path
         "../core/world.rkt" "../core/command.rkt" "../core/effect.rkt"
         "../layout/tree.rkt"
         "model.rkt" "adapter.rkt" "lifecycle.rkt" "region.rkt")

(define input-name "*input*")

(define (panel-vid-of w name)
  (define c (world-content w))
  (and c (content-panel-vid c name)))

(define (prompt-of w)
  (define c (world-content w))
  (and c (content-prompt c)))

;;; ---------- 打开 / 关闭 ----------

;; 打开 = 把 status dock 切到 *input* 成员并聚焦（不再自己换窗口 vid）。
(define (prompt-open w label kind data)
  (define c (world-content w))
  (define iv (panel-vid-of w input-name))
  (define sr (and c (region-ref w 'status)))
  (define sw (and sr (region-wid sr)))
  (cond
    [(or (not c) (not iv) (not sw)) w]
    [else
     (define ed (content-ed c))
     (assign! ed iv label)
     (set-point! ed iv 0 (string-length label))
     (define did (view-did ed iv))
     (face-line! ed did 0 'input)
     (readonly-range! ed did 0 0 0 (string-length label) #t)
     (define w1 (region-activate! w 'status input-name))
     (define w2 (world-set-content w1 (content-set-prompt (world-content w1)
                                                          (prompt label kind data (world-focus w)))))
     (world-set-focus w2 sw)]))

(define (prompt-close w)
  (define c (world-content w))
  (define p (and c (content-prompt c)))
  (cond
    [(not (and c p)) w]
    [else
     ;; 关闭 = 清 prompt + status dock 切回 *status*。
     (define w1 (world-set-content w (content-set-prompt c #f)))
     (define w2 (region-activate! w1 'status "*status*"))
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

;;; ---------- kind → handler（注册表；插件可加） ----------

(struct prompt-kind-registry (table) #:transparent)

(define (make-prompt-kind-registry [entries '()])
  (prompt-kind-registry (for/hash ([e (in-list entries)]) (values (car e) (cdr e)))))
(define (prompt-kind-register reg kind handler)
  (prompt-kind-registry (hash-set (prompt-kind-registry-table reg) kind handler)))
(define (prompt-kind-lookup reg kind)
  (hash-ref (prompt-kind-registry-table reg) kind #f))
(define (prompt-kind-merge a b)
  (make-prompt-kind-registry
   (append (for/list ([(k v) (in-hash (prompt-kind-registry-table a))]) (cons k v))
           (for/list ([(k v) (in-hash (prompt-kind-registry-table b))]) (cons k v)))))

(define base-prompt-kinds
  (make-prompt-kind-registry
   (list (cons 'close-doc kind-close-doc)
         (cons 'quit kind-quit)
         (cons 'new-file kind-new-file)
         (cons 'new-dir kind-new-dir)
         (cons 'delete kind-delete))))

;;; ---------- 提交流程 ----------

(define (prompt-submit kinds w)
  (define p (prompt-of w))
  (cond
    [(not p) (values w '())]
    [else
     (define text (prompt-answer w p))
     (define h (prompt-kind-lookup kinds (prompt-kind p)))
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

(define (request-close-doc w)
  (request-close-doc* w (focused-did w)))

(define (request-close-doc* w did)
  (define c (world-content w))
  (cond
    [(not did) (values w '())]
    [(doc-dirty? c did)
     (values (prompt-open w (format "save ~a? (y/n) " (doc-display w did)) 'close-doc (list did)) '())]
    [else (values (close-doc! w did) '())]))

;;; ---------- 命令 ----------

(define (as-result thunk) (call-with-values thunk cons))

(define (make-prompt-submit kinds)
  (lambda (ctx w args) (as-result (lambda () (prompt-submit kinds w)))))

(define (h-prompt-cancel ctx w args) (as-result (lambda () (prompt-cancel w))))
(define (h-quit ctx w args) (as-result (lambda () (request-quit w))))
(define (h-close-doc ctx w args) (as-result (lambda () (request-close-doc w))))

(define prompt-commands
  (make-command-registry
   (list (cons 'prompt-submit (make-prompt-submit base-prompt-kinds))
         (cons 'prompt-cancel h-prompt-cancel)
         (cons 'quit h-quit)
         (cons 'close-doc h-close-doc))))
