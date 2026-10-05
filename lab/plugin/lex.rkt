#lang racket

(require "../../core/text/base/line.rkt")

;;; lab/plugin/lex.rkt —— 极简词法：按行扫标识符 token（词着色 / 关键字插件共用）
;;;
;;; token = (list line start end text)。只认「标识符样」的连续段：
;;;   首字符：字母 / 下划线 / λ
;;;   后续  ：字母 / 数字 / 下划线 / ? ! * / < > = + : . -
;;; 不处理字符串 / 注释 / 字符字面量 —— 玩具级，够语法高亮用。

(provide scan-words)

(define ident-rx #px"[A-Za-z_\u03BB][A-Za-z0-9_\u03BB?!*/<>=+:.-]*")

(define (scan-words text)
  (append*
   (for/list ([line (in-list (string->lines text))] [ln (in-naturals)])
     (for/list ([m (in-list (regexp-match-positions* ident-rx line))])
       (list ln (car m) (cdr m) (substring line (car m) (cdr m)))))))
