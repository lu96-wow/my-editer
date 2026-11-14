#lang racket

;;; edit-tui/plugins/bilingual/translate.rkt —— 默认双语翻译器
;;;
;;; token 级 1:1 行映射：
;;;   · 只替换 symbol / keyword token，不碰字符串 / 注释 / 空白；
;;;   · 每行独立翻译，行号一一对应；
;;;   · 未知 token 原样保留，双向都成立。
;;;
;;; 数据来源：
;;;   data/racket-zh.rktd
;;;     第一行：CN symbol -> EN symbol
;;;     第二行：CN keyword -> EN keyword
;;;   由 scripts/import-tables.rkt 从 racket-translate-lang-build 生成。
;;;
;;; 运行时反转成 EN -> CN 做正向翻译；CN -> EN 直接用于反译。

(require racket/file
         racket/runtime-path
         (only-in "../../lang/racket/api.rkt"
                  tokenize-line
                  empty-lex-state
                  token-kind
                  token-start
                  token-end
                  keyword-category)
         "model.rkt")

(provide default-translator
         default-translator-id
         make-translator
         translator-rules->translator
         translator-with-overrides)

(struct rule (id source target) #:transparent)

(define default-translator-id 'zh-racket)

;; 兜底用：数据文件缺失 / 损坏时仍然有基本翻译。
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

;;; ════════════════ face ════════════════

(define explicit-faces
  (hash "define" 'bilingual-keyword
        "define-values" 'bilingual-keyword
        "lambda" 'bilingual-keyword
        "let" 'bilingual-keyword
        "let*" 'bilingual-keyword
        "letrec" 'bilingual-keyword
        "struct" 'bilingual-keyword
        "match" 'bilingual-keyword
        "cond" 'bilingual-keyword
        "if" 'bilingual-control
        "else" 'bilingual-control
        "begin" 'bilingual-control
        "and" 'bilingual-control
        "or" 'bilingual-control
        "not" 'bilingual-control
        "require" 'bilingual-module
        "provide" 'bilingual-module
        "set!" 'bilingual-binding
        "map" 'bilingual-function
        "filter" 'bilingual-function
        "foldl" 'bilingual-function
        "foldr" 'bilingual-function
        "null?" 'bilingual-function
        "cons" 'bilingual-function
        "car" 'bilingual-function
        "cdr" 'bilingual-function
        "list" 'bilingual-function))

(define (en-face en)
  (define s (symbol->string en))
  (or (hash-ref explicit-faces s #f)
      (case (keyword-category s)
        [(def macro) 'bilingual-keyword]
        [(control) 'bilingual-control]
        [(binding) 'bilingual-binding]
        [(module) 'bilingual-module]
        [else #f])))

(define (rule-face id)
  (en-face id))

;;; ════════════════ 行内替换 ════════════════

;; mapping : hash token-string -> (cons replacement (or/c face #f))
;; → (values text spans)
;;   spans 位置基于输出 text 的字符索引，不依赖 source 列。
(define (replace-symbols line mapping)
  (define-values (_state tokens) (tokenize-line empty-lex-state line))
  (define out '())
  (define out-len 0)
  (define spans '())
  (define (emit! s)
    (set! out (cons s out))
    (set! out-len (+ out-len (string-length s))))
  (define pos 0)
  (for ([tok (in-list tokens)])
    (define s (token-start tok))
    (define e (token-end tok))
    (when (> s pos)
      (emit! (substring line pos s)))
    (define text (substring line s e))
    (define mapped
      (and (eq? (token-kind tok) 'symbol)
           (hash-ref mapping text #f)))
    (define replacement (if mapped (car mapped) text))
    (define face (and mapped (cdr mapped)))
    (when face
      (set! spans
            (cons (list out-len
                        (+ out-len (string-length replacement))
                        face)
                  spans)))
    (emit! replacement)
    (set! pos e))
  (when (< pos (string-length line))
    (emit! (substring line pos)))
  (values (apply string-append (reverse out)) (reverse spans)))

(define (text-only mapping line)
  (define-values (text _spans) (replace-symbols line mapping))
  text)

;;; ════════════════ translator 构造 ════════════════

(define (translator-maps->translator id version forward inverse)
  (translator id version
              forward inverse
              (lambda (line) (text-only forward line))
              (lambda (line) (replace-symbols line forward))
              (lambda (line) (text-only inverse line))))

;; 在静态 translator 上叠加动态词典。动态 map 形状与 translator 内部 map 一致：
;;   forward : EN string -> (cons CN string face)
;;   inverse : CN string -> (cons EN string #f)
(define (hash-overlay base over)
  (for/fold ([h (make-immutable-hash (hash->list base))])
            ([(k v) (in-hash over)])
    (hash-set h k v)))

(define (translator-with-overrides base dynamic-forward dynamic-inverse
                                  #:version [version (translator-version base)])
  (translator-maps->translator
   (translator-id base)
   version
   (hash-overlay (translator-forward base) dynamic-forward)
   (hash-overlay (translator-inverse base) dynamic-inverse)))

(define (rules->maps rules)
  (values
   (for/fold ([h (hash)]) ([r (in-list rules)])
     (hash-set h (rule-source r)
               (cons (rule-target r) (rule-face (rule-id r)))))
   (for/fold ([h (hash)]) ([r (in-list rules)])
     (hash-set h (rule-target r) (cons (rule-source r) #f)))))

(define (translator-rules->translator id version rules)
  (define-values (forward inverse) (rules->maps rules))
  (translator-maps->translator id version forward inverse))

(define (make-translator #:id id #:version [version 'v1] #:rules rules)
  (translator-rules->translator id version rules))

;;; ════════════════ 数据表 ════════════════

(define-runtime-path translation-data "data/racket-zh.rktd")

(define (read-translation-data path)
  (call-with-input-file path
    (lambda (in)
      (define id-table (read in))
      (define kw-table (read in))
      (values (if (hash? id-table) id-table (hash))
              (if (hash? kw-table) kw-table (hash))))))

;; id-table : CN symbol -> EN symbol
;; kw-table : CN keyword -> EN keyword
(define (tables->maps id-table kw-table)
  (define forward (make-hash))
  (define inverse (make-hash))

  ;; 按 CN key 排序，保证同一 EN 有多个 CN 时选择稳定。
  (for ([entry (in-list (sort (hash->list id-table) symbol<? #:key car))])
    (define cn (symbol->string (car entry)))
    (define en (cdr entry))
    (define en-s (symbol->string en))
    (hash-set! inverse cn (cons en-s #f))
    (hash-set! forward en-s (cons cn (en-face en))))

  (for ([entry (in-list (sort (hash->list kw-table) keyword<? #:key car))])
    (define cn (string-append "#:" (keyword->string (car entry))))
    (define en (string-append "#:" (keyword->string (cdr entry))))
    (hash-set! inverse cn (cons en #f))
    (hash-set! forward en (cons cn #f)))

  (values forward inverse))

(define (load-default-translator)
  (cond
    [(file-exists? translation-data)
     (with-handlers ([exn:fail?
                      (lambda (_)
                        (translator-rules->translator
                         default-translator-id 'v1 default-rules))])
       (define-values (id-table kw-table)
         (read-translation-data translation-data))
       (define-values (forward inverse)
         (tables->maps id-table kw-table))
       (translator-maps->translator
        default-translator-id 'v2 forward inverse))]
    [else
     (translator-rules->translator default-translator-id 'v1 default-rules)]))

(define default-translator (load-default-translator))
