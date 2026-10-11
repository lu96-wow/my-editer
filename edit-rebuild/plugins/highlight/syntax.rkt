#lang racket

;;; edit-rebuild/plugins/highlight/syntax.rkt —— 语法（关键字）高亮插件（输入时不变色）
;;;
;;; 只对 Racket 源文件生效（applies? 按扩展名）；关键字按**语义分组**取色。
;;; 无词表状态；唯一状态是「正在输入的词」（同 words.rkt）：该 token 本次不上色，
;;; 下次编辑重扫它的行再按完整词上色。光标移动不改色。

(require "../../core/extension/face-plugin.rkt"
         "../../core/extension/spec.rkt"
         "../../core/face/lex.rkt"
         "../../core/face/kind.rkt"
         "../../core/face/face.rkt"
         "../../core/face/line-scan.rkt"
         "../config/syntax.rkt")

(provide syntax-plugin syntax-spec)

;; 组 → 色板下标
(define category-index
  (for/hash ([c (in-list keyword-category-order)] [i (in-naturals)]) (values c i)))

(define (keyword-face w)
  (palette-color 'keyword (hash-ref category-index (hash-ref keyword-categories w))))

;; 行 → face 向量（无关键字 → #f）。pending = (list line start end) | #f，跳过它。
(define (syntax-line pending line-no line)
  (define n (string-length line))
  (define faces (make-vector n #f))
  (define touched? #f)
  (for ([m (in-list (line-tokens line))])
    (define start (car m))
    (define end (cdr m))
    (unless (and pending (= line-no (car pending)) (= start (cadr pending)))
      (define w (substring line start end))
      (define cat (hash-ref keyword-categories w #f))
      (when cat
        (set! touched? #t)
        (define f (keyword-face w))
        (for ([i (in-range start end)]) (vector-set! faces i f)))))
  (and touched? faces))

(define (syntax-open text _path)
  (values #f (scan-track text (lambda (ln line) (syntax-line #f ln line)))))

;; 同 words.rkt：有编辑看编辑点，纯光标移动则判断是否「编辑完」。
(define (next-pending pending ctx)
  (define changes (face-ctx-changes ctx))
  (cond
    [(pair? changes) (edit-word changes (face-ctx-new-text ctx))]
    [else (define cw (cursor-word (face-ctx-new-text ctx) (face-ctx-cursor ctx)))
          (if (equal? pending cw) pending #f)]))

(define (syntax-change pending layer ctx)
  (define new-text (face-ctx-new-text ctx))
  (define changes (face-ctx-changes ctx))
  (define new-pending (next-pending pending ctx))
  (define old-line (and pending (car pending)))
  (define new-line (and new-pending (car new-pending)))
  (values new-pending
          (refresh-layer layer new-text changes
                         (filter values (list old-line new-line))
                         (lambda (ln line) (syntax-line new-pending ln line)))
          (dirty-union (face-ctx-dirty ctx)
                       (dirty-lines (filter values (list old-line new-line))))))

(define syntax-plugin
  (face-plugin 'syntax racket-applies? syntax-open syntax-change))

(define syntax-spec
  (plugin-spec 'syntax (lambda (s) s) (list syntax-plugin)))
