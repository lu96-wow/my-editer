#lang racket

;;; edit-tui-rebuild/command/key.rkt —— 键 token（纯）
;;;
;;; (key 'p 'ctrl) / (key 'left) / (key #\space)
;;; 规范修饰键顺序：ctrl alt shift。
;;;
;;; 注意：有些 C- 组合在传统 ANSI 终端里根本收不到（见 key-deliverable?）。

(provide mods-order normalize-mods
         key key? key-name key-mods key->string
         char->key-name
         key-deliverable?)

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

;;; ── 终端可达性 ──
;;;
;;; 传统 ANSI / xterm 把控制键编码成单个字节，tui 先按字节分类
;;; (tui/base/io/input.rkt classify-byte)，再归一成命名键
;;; (tui/base/io/event.rkt byte->key)。于是下面这些字节会被识别成别的键，
;;; 对应的 C- 组合永远收不到：
;;;
;;;   C-i -> tab          C-h -> backspace     C-j / C-m -> enter
;;;   C-[ -> escape       C-? -> backspace     C-space / C-@ -> NUL
;;;   C-\ C-] C-^ C-_ -> 裸控制字符（没有 ctrl 修饰）
;;;   C-tab / C-enter / C-backspace / C-escape -> 未修饰的那个键
;;;
;;; 想用这些组合得靠 kitty keyboard protocol / xterm modifyOtherKeys；
;;; 在 ANSI 下请换键（例如 C-e）。
(define ansi-shadowed-ctrl-names
  '(h i j m space @ nul |[| |\\| |]| ^ _ ? tab enter backspace escape))

;; ctrl 组合是否可能被终端独立送达？非 ctrl / 未修饰的键一律视为可达。
(define (key-deliverable? k)
  (cond
    [(not (key? k)) #f]
    [(not (memq 'ctrl (key-mods k))) #t]
    [else
     (define n (key-name k))
     (define n* (if (symbol? n)
                    (string->symbol (string-downcase (symbol->string n)))
                    n))
     (not (memq n* ansi-shadowed-ctrl-names))]))

(define (key->string k)
  (define mods (key-mods k))
  (string-append
   (if (memq 'ctrl mods) "C-" "")
   (if (memq 'alt mods) "M-" "")
   (if (memq 'shift mods) "S-" "")
   (let ([n (key-name k)])
     (if (eq? n 'space) "Space" (symbol->string n)))))
