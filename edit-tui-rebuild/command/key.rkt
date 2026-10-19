#lang racket

;;; edit-tui-rebuild/command/key.rkt —— 键 token（纯）
;;;
;;; (key 'p 'ctrl) / (key 'left) / (key #\space)
;;; 规范修饰键顺序：ctrl alt shift。

(provide mods-order normalize-mods
         key key? key-name key-mods key->string
         char->key-name)

(define mods-order '(ctrl alt shift))

(struct key-token (name mods) #:transparent)

(define (normalize-mods mods)
  (for/list ([m (in-list mods-order)] #:when (memq m mods)) m))

(define (char->key-name c)
  (case c
    [(#\space) 'space]
    [else (string->symbol (string-downcase (string c)))]))

(define (->key-name x)
  (cond [(symbol? x) x]
        [(char? x) (char->key-name x)]
        [else (error 'key "键名要是 symbol 或 char：~a" x)]))

(define (key name . mods)
  (key-token (->key-name name) (normalize-mods mods)))

(define key? key-token?)
(define key-name key-token-name)
(define key-mods key-token-mods)

(define (key->string k)
  (define mods (key-mods k))
  (string-append
   (if (memq 'ctrl mods) "C-" "")
   (if (memq 'alt mods) "M-" "")
   (if (memq 'shift mods) "S-" "")
   (let ([n (key-name k)])
     (if (eq? n 'space) "Space" (symbol->string n)))))
