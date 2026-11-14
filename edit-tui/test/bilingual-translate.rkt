#lang racket

;;; bilingual 默认翻译器：加载插件内置的完整 Racket 翻译表。

(require rackunit
         racket/string
         (only-in "../plugins/bilingual/model.rkt"
                  translator-translate-line
                  translator-translate-line+faces
                  translator-inverse-line)
         "../plugins/bilingual/translate.rkt")

(define tr default-translator)

;; symbol 翻译来自完整表。
(check-equal? ((translator-translate-line tr)
               "(define (f x) (map add1 x))")
              "(定义 (f x) (映射 加1 x))")

;; token face 只落在替换后的 token 上。
(define-values (text spans)
  ((translator-translate-line+faces tr)
   "(define (f x) (map add1 x))"))
(check-equal? text "(定义 (f x) (映射 加1 x))")
(check-equal? spans '((1 3 bilingual-keyword)
                      (11 13 bilingual-function)))

;; keyword 也走同一张表；字符串 / 注释不翻译。
(define line "(open-output-file p #:exists (quote append)) ; comment define \"define\"")
(define translated ((translator-translate-line tr) line))
(check-true (string-contains? translated "打开-输出-文件"))
(check-true (string-contains? translated "#:存在"))
(check-true (string-contains? translated "(引用 追加)"))
(check-true (string-contains? translated "; comment define \"define\""))
(check-equal? ((translator-inverse-line tr) translated) line)

;; 未知 token 原样保留。
(check-equal? ((translator-translate-line tr) "(my-user-name x)")
              "(my-user-name x)")

(displayln "edit-tui/test/bilingual-translate.rkt: ok")
