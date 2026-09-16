#lang racket

;;; plugin/racket-hl.rkt —— 示例文档插件：语法高亮（buffer -> (listof patch)）
;;;
;;; 说明：
;;;   - 纯函数，不知道线程（mode 由调用者在 plugin-spec 里声明）
;;;   - 增量依据 = buffer-dirty：每个 dirty 行产出一个 patch
;;;   - 只 (require "../plugin/annotate-api.rkt")，证明契约面已足够

(require "../plugin/annotate-api.rkt")

(provide keyword-hl)

(define keyword-rx #px"\\b(define|lambda|if|cond|let|for|match|and|or|not)\\b")
(define string-rx  #px"\"[^\"]*\"")
(define comment-rx #px";[^\n]*")

(define (matches->segs line rx face text)
  (for/list ([m (in-list (regexp-match-positions* rx text))])
    (list line (car m) (cdr m) face)))

;; 语法高亮插件：buffer -> (listof patch)，纯、不知道线程。
;; 每个 dirty 行产出一个 patch：先清该行 'face 旧值，再写新 segs。
(define (keyword-hl b)
  (define d (buffer-dirty b))
  (if (not d)
      '()
      (for/list ([line (in-range (dirty-desc-first-line d)
                                 (add1 (dirty-desc-last-line d)))])
        (define text (buffer-line-ref b line))
        (patch 'face line line
               (append
                (matches->segs line keyword-rx 'keyword text)
                (matches->segs line string-rx  'string  text)
                (matches->segs line comment-rx 'comment text))))))
