#lang racket

;;; edit-tui/plugins/bilingual/words.rkt —— 从 completion 词表收集待翻译词
;;;
;;; 不使用 completion popup 的 prefix-filter 结果；这里拿完整 pool：
;;;   local pool    当前 buffer symbol / workspace 本地定义 / 关键字
;;;   required pool require / #lang 引入模块的导出名
;;;
;;; 只负责“产生候选词”，不判断是否已在静态 / 动态词典里；去重 / 过滤在这里做。

(require racket/string
         "../../editor/api.rkt"
         "../../features/open-buffers/api.rkt"
         "../../lang/racket/api.rkt")

(provide bilingual-word-candidates)

(define (valid-word? s)
  (and (string? s)
       (> (string-length s) 1)
       (not (string-prefix? s "#%"))
       (not (regexp-match? #rx"\\s" s))
       (for/or ([c (in-string s)]) (char-alphabetic? c))))

(define (distinct-strings ss)
  (define seen (make-hash))
  (reverse
   (for/fold ([acc '()]) ([s (in-list ss)])
     (cond
       [(hash-ref seen s #f) acc]
       [else (hash-set! seen s #t) (cons s acc)]))))

(define (bilingual-word-candidates ed state did)
  (define text (editor-doc-text ed did))
  (define r (state-resource-for-doc state did))
  (define path (and r (resource-path r)))
  (define ws (editor-workspace ed))
  (cond
    [(or (not text)
         (not r)
         (not (eq? (resource-mode r) 'racket)))
     '()]
    [else
     (define open
       (if (and ws (workspace-doc ws did))
           (hash)
           (editor-open-texts ed state)))
     (define ctx
       (with-handlers ([exn:fail? (λ (_) #f)])
         (make-completion-context path text
                                  #:open open
                                  #:workspace ws
                                  #:id did)))
     (cond
       [(not ctx) '()]
       [else
        ;; local 优先，required 后置；最终顺序稳定，方便 batch。
        (distinct-strings
         (filter valid-word?
                 (append (completion-local-pool ctx)
                         (completion-required-pool ctx))))])]))
