#lang racket

(require "../../../core/text/base/line.rkt")

;;; lab-rebuild/plugin/lex.rkt —— 极简词法：按行扫标识符 token（词着色 / 关键字插件共用）
;;;
;;; token = (list line start end text)。只认「标识符样」的连续段：
;;;   首字符：字母 / 下划线 / λ
;;;   后续  ：字母 / 数字 / 下划线 / ? ! * / < > = + : . -
;;; 不处理字符串 / 注释 / 字符字面量 —— 玩具级，够语法高亮用。

(provide scan-words word-token-at active-token)

(define ident-rx #px"[A-Za-z_\u03BB][A-Za-z0-9_\u03BB?!*/<>=+:.-]*")

(define (scan-words text)
  (append*
   (for/list ([line (in-list (string->lines text))] [ln (in-naturals)])
     (for/list ([m (in-list (regexp-match-positions* ident-rx line))])
       (list ln (car m) (cdr m) (substring line (car m) (cdr m)))))))

;; 第 line 行第 col 个字符落在哪个标识符 token 里 → (list start end) / #f。
(define (word-token-at line col)
  (for/first ([m (in-list (regexp-match-positions* ident-rx line))]
              #:when (and (<= (car m) col) (< col (cdr m))))
    (list (car m) (cdr m))))

;; “正在输入的那个词” = 光标（编辑插入文本末尾）前一个字符所在的 token。
;; 词着色 / 关键字都跳过它，等词定下来再上色 —— 否则边打字边加长会每键换色。
;; → #f | (list line start end)；多编辑 / 越界 → #f。
(define (active-token lines edits)
  (and (= 1 (length edits))
       (let* ([e (car edits)]
              [l0 (list-ref e 0)] [c0 (list-ref e 1)]
              [inserted (list-ref e 4)]
              [parts (string->lines inserted)]
              [pt (if (= 1 (length parts))
                      (list l0 (+ c0 (string-length inserted)))
                      (list (+ l0 (sub1 (length parts))) (string-length (last parts))))]
              [ln (car pt)])
         (and (< ln (vector-length lines))
              (let* ([line (vector-ref lines ln)]
                     [col (max 0 (sub1 (cadr pt)))])
                (and (< col (string-length line))
                     (let ([t (word-token-at line col)])
                       (and t (list ln (car t) (cdr t))))))))))
