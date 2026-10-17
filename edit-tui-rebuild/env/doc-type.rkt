#lang racket

;;; env/doc-type.rkt —— 文件 / document 类型注册项（纯值）
;;;
;;; document-type 决定“打开一个路径时，新 document 携带什么”：
;;;   extensions : 匹配的扩展名（小写，不带点；'("*") = 任意）
;;;   mode       : 默认 mode（决定默认 keymaps）
;;;   keymaps    : per-document 覆盖层（打开时写进 doc-meta.keymap-layers）
;;;
;;; 这就是“打开 / 关闭匹配 document 和命令 list”的扩展点：
;;;   · 打开：按路径选 doc-type，把 mode + keymaps 装进 doc-meta；
;;;   · 关闭：doc-meta 已携带这些信息，close-doc 不需要再猜。
;;;
;;; 只描述“打开时携带什么”，不在这里执行 IO。

(provide (struct-out doc-type)
         make-doc-type
         doc-type-matches-path?)

(require racket/path
         racket/string
         "../base/keymap.rkt")

(struct doc-type (name extensions mode keymaps) #:transparent)
;; name       : symbol
;; extensions : (listof string)  小写、无点；'("*") 匹配任意扩展名
;; mode       : symbol
;; keymaps    : (listof keymap)

(define (make-doc-type name
                       #:extensions [extensions '()]
                       #:mode [mode 'text]
                       #:keymaps [keymaps '()])
  (unless (symbol? name)
    (error 'make-doc-type "name 要是 symbol：~a" name))
  (for ([km (in-list keymaps)])
    (unless (keymap? km)
      (error 'make-doc-type "keymaps 里要 keymap：~a" km)))
  (doc-type name
            (for/list ([e (in-list extensions)])
              (string-downcase (string-trim (regexp-replace #rx"^\\." (string-downcase e) ""))))
            mode keymaps))

(define (path-extension path)
  (define e (filename-extension path))
  (and e (string-downcase (bytes->string/utf-8 e))))

(define (doc-type-matches-path? dt path)
  (define ext (path-extension path))
  (for/or ([e (in-list (doc-type-extensions dt))])
    (or (string=? e "*")
        (and ext (string=? e ext)))))
