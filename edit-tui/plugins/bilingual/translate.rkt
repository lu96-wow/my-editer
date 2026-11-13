#lang racket

;;; edit-tui/plugins/bilingual/translate.rkt —— 默认双语翻译器
;;;
;;; 第一版是 token 级 1:1 行映射：
;;;   · 只替换 symbol token，不碰字符串 / 注释 / 空白；
;;;   · 每行独立翻译，行号一一对应；
;;;   · 未知 token 原样保留，双向都成立。
;;;
;;; 以后接结构化数据源时，保持 translator 的 translate-line / inverse-line
;;; 协议即可，不需要改 pair / plugin / host。

(require (only-in "../../lang/racket/api.rkt"
                  tokenize-line
                  empty-lex-state
                  token-kind
                  token-start
                  token-end)
         "model.rkt")

(provide default-translator
         default-translator-id
         make-translator
         translator-rules->translator)

(struct rule (id source target) #:transparent)

(define default-translator-id 'zh-racket)

(define default-rules
  (list
   (rule 'define "define" "定义")
   (rule 'define-values "define-values" "定义值")
   (rule 'lambda "lambda" "函数")
   (rule 'let "let" "让")
   (rule 'let* "let*" "让*")
   (rule 'letrec "letrec" "让递归")
   (rule 'if "if" "如果")
   (rule 'cond "cond" "条件")
   (rule 'else "else" "否则")
   (rule 'begin "begin" "开始")
   (rule 'set! "set!" "设置!")
   (rule 'require "require" "引入")
   (rule 'provide "provide" "提供")
   (rule 'struct "struct" "结构")
   (rule 'match "match" "匹配")
   (rule 'and "and" "且")
   (rule 'or "or" "或")
   (rule 'not "not" "非")
   (rule 'map "map" "映射")
   (rule 'filter "filter" "过滤")
   (rule 'foldl "foldl" "左折叠")
   (rule 'foldr "foldr" "右折叠")
   (rule 'null? "null?" "空?")
   (rule 'cons "cons" "构造")
   (rule 'car "car" "首")
   (rule 'cdr "cdr" "尾")
   (rule 'list "list" "列表")))

(define (replace-symbols line mapping)
  (define-values (_state tokens) (tokenize-line empty-lex-state line))
  (define out '())
  (define pos 0)
  (for ([tok (in-list tokens)])
    (define s (token-start tok))
    (define e (token-end tok))
    (when (> s pos)
      (set! out (cons (substring line pos s) out)))
    (define text (substring line s e))
    (define replacement
      (if (eq? (token-kind tok) 'symbol)
          (hash-ref mapping text text)
          text))
    (set! out (cons replacement out))
    (set! pos e))
  (when (< pos (string-length line))
    (set! out (cons (substring line pos) out)))
  (apply string-append (reverse out)))

(define (rules->maps rules)
  (values
   (for/fold ([h (hash)]) ([r (in-list rules)])
     (hash-set h (rule-source r) (rule-target r)))
   (for/fold ([h (hash)]) ([r (in-list rules)])
     (hash-set h (rule-target r) (rule-source r)))))

(define (translator-rules->translator id version rules)
  (define-values (forward inverse) (rules->maps rules))
  (translator id version
              (lambda (line) (replace-symbols line forward))
              (lambda (line) (replace-symbols line inverse))))

(define (make-translator #:id id #:version [version 'v1] #:rules rules)
  (translator-rules->translator id version rules))

(define default-translator
  (translator-rules->translator default-translator-id 'v1 default-rules))
