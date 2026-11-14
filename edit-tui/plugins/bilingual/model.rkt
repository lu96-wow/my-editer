#lang racket

;;; edit-tui/plugins/bilingual/model.rkt —— 双语插件纯值模型
;;;
;;; translator : 纯行翻译器（1:1 行映射）
;;; pair       : source user doc 与 mirror derived doc 的关联
;;; state      : 插件状态；只有 plugin runtime 按 owner 写回

(require racket/string
         "lexicon.rkt")

(provide (struct-out translator)
         (struct-out pair)
         (struct-out bilingual-state)
         make-bilingual-state
         pair-for-source
         pair-for-mirror
         state-translator
         state-set-translator
         state-lexicon
         state-set-lexicon
         state-set-pair
         state-remove-pair
         split-lines
         line-diff)

;; translate-line / inverse-line : string -> string
;; translate-line+faces : string -> (values string spans)
;;   spans = (listof (list start end face))，位置基于 mirror 行自身字符索引。
;; 第一版不做“反译失败”；无法识别的 token 原样保留。
(struct translator
  (id
   version
   forward      ; EN string -> (cons CN string face)
   inverse      ; CN string -> (cons EN string #f)
   translate-line
   translate-line+faces
   inverse-line)
  #:transparent)

(struct pair
  (source-doc-id
   mirror-doc-id
   mirror-view-id
   translator-id
   translator-version
   source-version
   mirror-version
   pending-version       ; 已调度 / 已提交的 source version
   pending-job-id
   timer-id
   source-lines
   mirror-lines
   mirror-faces          ; (listof vector)：每行逐字符 face
   source-anchor         ; (cons line col) | #f：viewport 左上锚点
   mirror-anchor         ; 同上
   force-full?)          ; 需要下一次投影强制 full
  #:transparent)

(struct bilingual-state
  (pairs               ; hash source-doc-id -> pair
   translators         ; hash translator-id -> translator
   default-translator-id
   lexicon)            ; 动态词翻译
  #:transparent)

(define (make-bilingual-state translators default-id [lexicon empty-lexicon])
  (bilingual-state (hash) translators default-id lexicon))

(define (pair-for-source ps did)
  (and (bilingual-state? ps)
       (hash-ref (bilingual-state-pairs ps) did #f)))

(define (pair-for-mirror ps did)
  (and (bilingual-state? ps)
       (for/first ([p (in-hash-values (bilingual-state-pairs ps))]
                   #:when (equal? (pair-mirror-doc-id p) did))
         p)))

(define (state-translator ps id)
  (and (bilingual-state? ps)
       (hash-ref (bilingual-state-translators ps) id #f)))

(define (state-set-translator ps id tr)
  (struct-copy bilingual-state ps
               [translators
                (hash-set (bilingual-state-translators ps) id tr)]))

(define (state-lexicon ps)
  (if (bilingual-state? ps)
      (bilingual-state-lexicon ps)
      empty-lexicon))

(define (state-set-lexicon ps lex)
  (struct-copy bilingual-state ps [lexicon lex]))

(define (state-set-pair ps p)
  (struct-copy bilingual-state ps
               [pairs (hash-set (bilingual-state-pairs ps)
                                (pair-source-doc-id p)
                                p)]))

(define (state-remove-pair ps source-did)
  (struct-copy bilingual-state ps
               [pairs (hash-remove (bilingual-state-pairs ps) source-did)]))

(define (split-lines text)
  (if text
      (string-split text "\n" #:trim? #f)
      '()))

;; old / new : (listof string)
;; → (values old-start old-end new-start new-end)
;; 用 common line prefix / suffix 找变化块；空变化块表示没有行级差异。
(define (line-diff old new)
  (define ov (list->vector old))
  (define nv (list->vector new))
  (define on (vector-length ov))
  (define nn (vector-length nv))
  (define max-prefix (min on nn))
  (define p
    (let loop ([i 0])
      (cond
        [(>= i max-prefix) i]
        [(equal? (vector-ref ov i) (vector-ref nv i)) (loop (add1 i))]
        [else i])))
  (define max-suffix (- (min on nn) p))
  (define s
    (let loop ([i 0])
      (cond
        [(>= i max-suffix) i]
        [(equal? (vector-ref ov (- on 1 i))
                 (vector-ref nv (- nn 1 i)))
         (loop (add1 i))]
        [else i])))
  (values p (- on s) p (- nn s)))
