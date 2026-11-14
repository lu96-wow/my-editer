#lang racket

;;; edit-tui/plugins/bilingual/lexicon.rkt —— 动态词翻译词典（纯）
;;;
;;; 静态表在 data/racket-zh.rktd；这里只存运行时补充的项目词。
;;;
;;; forward : EN string -> (cons CN string face)
;;; inverse : CN string -> EN string
;;; pending : EN string -> #t（当前 job 正在翻译的词）
;;; generation : 每次真正加入新词后 +1
;;; job-id : 当前 word-translate job | #f

(require racket/list
         racket/string)

(provide (struct-out lexicon)
         empty-lexicon
         lexicon-known?
         lexicon-pending?
         lexicon-set-job-id
         lexicon-add-pending
         lexicon-clear-pending
         lexicon-clear-all-pending
         lexicon-merge)

(struct lexicon
  (forward inverse pending generation job-id)
  #:transparent)

(define empty-lexicon
  (lexicon (hash) (hash) (hash) 0 #f))

(define (lexicon-known? lex word)
  (hash-has-key? (lexicon-forward lex) word))

(define (lexicon-pending? lex word)
  (hash-has-key? (lexicon-pending lex) word))

(define (lexicon-set-job-id lex job-id)
  (struct-copy lexicon lex [job-id job-id]))

(define (lexicon-add-pending lex words)
  (struct-copy lexicon lex
               [pending
                (for/fold ([h (lexicon-pending lex)]) ([w (in-list words)])
                  (hash-set h w #t))]))

(define (lexicon-clear-pending lex words)
  (struct-copy lexicon lex
               [pending
                (for/fold ([h (lexicon-pending lex)]) ([w (in-list words)])
                  (hash-remove h w))]))

(define (lexicon-clear-all-pending lex)
  (struct-copy lexicon lex [pending (hash)]))

;;; ════════════════ 合并外部翻译结果 ════════════════

(define (normalize-word x)
  (and (string? x)
       (let ([s (string-trim x)])
         (and (not (string=? s "")) s))))

;; entries : (listof (list EN CN [face]))
;; base-forward : EN -> (cons CN face)
;; base-inverse : CN -> (cons EN #f)
;; → (values lexicon' added conflicts)
(define (lexicon-merge lex entries base-forward base-inverse)
  (define-values (forward* inverse* added conflicts)
    (for/fold ([forward (lexicon-forward lex)]
               [inverse (lexicon-inverse lex)]
               [added '()]
               [conflicts '()])
              ([entry (in-list entries)])
      (let* ([en (and (pair? entry) (normalize-word (car entry)))]
             [cn (and (pair? entry) (pair? (cdr entry))
                      (normalize-word (cadr entry)))]
             [face (and (pair? entry) (pair? (cdr entry))
                        (pair? (cddr entry)) (caddr entry))])
        (cond
          [(or (not en) (not cn))
           (values forward inverse added
                   (cons (list 'invalid entry) conflicts))]
          [(string=? en cn)
           (values forward inverse added conflicts)]
          [else
           (let ([static-forward (hash-ref base-forward en #f)]
                 [dynamic-forward (hash-ref forward en #f)]
                 [static-inverse (hash-ref base-inverse cn #f)]
                 [dynamic-inverse (hash-ref inverse cn #f)])
             (cond
               ;; 已经存在且一致：不重复加入。
               [(and static-forward (equal? (car static-forward) cn))
                (values forward inverse added conflicts)]
               [(and dynamic-forward (equal? (car dynamic-forward) cn))
                (values forward inverse added conflicts)]
               [(and static-inverse (equal? (car static-inverse) en))
                (values forward inverse added conflicts)]
               [(and dynamic-inverse (equal? dynamic-inverse en))
                (values forward inverse added conflicts)]

               ;; EN 已有不同翻译：静态表 / 动态词典都不覆盖。
               [static-forward
                (values forward inverse added
                        (cons (list 'static-en-conflict en cn
                                    (car static-forward))
                              conflicts))]
               [dynamic-forward
                (values forward inverse added
                        (cons (list 'dynamic-en-conflict en cn
                                    (car dynamic-forward))
                              conflicts))]

               ;; CN 已经指向别的 EN：拒绝，避免反译歧义。
               [static-inverse
                (values forward inverse added
                        (cons (list 'static-cn-conflict en cn
                                    (car static-inverse))
                              conflicts))]
               [dynamic-inverse
                (values forward inverse added
                        (cons (list 'dynamic-cn-conflict en cn
                                    dynamic-inverse)
                              conflicts))]

               [else
                (values (hash-set forward en (cons cn face))
                        (hash-set inverse cn en)
                        (cons (list en cn face) added)
                        conflicts)]))]))))
  (define lex*
    (struct-copy lexicon lex
                 [forward forward*]
                 [inverse inverse*]
                 [generation
                  (if (null? added)
                      (lexicon-generation lex)
                      (add1 (lexicon-generation lex)))]))
  (values lex* added conflicts))
