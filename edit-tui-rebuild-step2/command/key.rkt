#lang racket

;;; layer  : command
;;; effect : 无（纯键 token）

;;; command/key.rkt —— 按键令牌（纯，不碰 tui）
;;;
;;; 一个「键」= 键名 + 一组规范化修饰键，用 equal? 比较：
;;;
;;;     (key 'p 'ctrl)        Ctrl+P
;;;     (key 'left)           ←
;;;     (key 'a 'ctrl 'alt)   Ctrl+Alt+A
;;;
;;; 键名是符号：命名键（'left 'enter 'tab 'backspace …）原样；可打印字符取
;;; 小写符号（'a 'space …）。终端无法区分 Ctrl+A 与 Ctrl+Shift+A（kitty 协议
;;; 之外），所以字符键一律小写、Shift 只对命名键有意义。
;;;
;;; 本模块不 require tui：「事件 → 键」的解码在 command/tui.rkt。

(provide mods-order normalize-mods
         key key? key-name key-mods key->string
         char->key-name)

;; 修饰键的规范顺序：构造 / 打印 / 比较都按它，保证相等性稳定。
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
        [else (error 'key "键名要是 symbol 或 char，得到 ~a" x)]))

;; 构造令牌。(key 'p 'ctrl 'shift) / (key #\space) / (key 'left)
(define (key name . mods)
  (key-token (->key-name name) (normalize-mods mods)))

(define key? key-token?)
(define key-name key-token-name)
(define key-mods key-token-mods)

;; 显示用：C-x / M-left / S-tab / a / Space
(define (key->string k)
  (define mods (key-mods k))
  (string-append
   (if (memq 'ctrl mods) "C-" "")
   (if (memq 'alt mods) "M-" "")
   (if (memq 'shift mods) "S-" "")
   (let ([n (key-name k)])
     (if (eq? n 'space) "Space" (symbol->string n)))))
