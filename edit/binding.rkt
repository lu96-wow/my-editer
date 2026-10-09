#lang racket

;;; edit/binding.rkt —— 事件 → 匿名绑定键（纯，依赖 racket-tui 的事件结构）
;;;
;;; 输入是 racket-tui 的规范化事件；输出是键表用的绑定键：
;;;     (key k ctrl …)        命名键 / 带修饰的字符键
;;;     text / paste / resize 特殊通道
;;;     (mouse action button mods)
;;; 键表与事件编码解耦：换后端只要换这一层。

(require tui)

(provide key mouse text-binding paste-binding resize-binding
         event->binding event-text)

(define mod-order '(ctrl alt shift))

(define (normalize-mods mods)
  (for/list ([m (in-list mod-order)] #:when (memq m mods)) m))

(define (mods->symbols m)
  (for/list ([sym (in-list mod-order)]
             [on? (in-list (list (mods-ctrl? m) (mods-alt? m) (mods-shift? m)))]
             #:when on?)
    sym))

(define (char->key-symbol c)
  (if (char=? c #\space) 'space (string->symbol (string-downcase (string c)))))

;; 构造绑定键（config 用）。
(define (key k . mods) (list 'key k (normalize-mods mods)))
(define (mouse action [button #f] [mods '()]) (list 'mouse action button (normalize-mods mods)))
(define text-binding 'text)
(define paste-binding 'paste)
(define resize-binding 'resize)

;; 事件 → 绑定键（无法绑定的 → #f）。
(define (event->binding e)
  (cond
    [(key-event? e)
     (define k (key-event-key e))
     (define m (key-event-mods e))
     (cond
       [(and (char? k) (not (mods-ctrl? m)) (not (mods-alt? m))) text-binding]
       [else (list 'key (if (char? k) (char->key-symbol k) k) (mods->symbols m))])]
    [(paste-event? e) paste-binding]
    [(mouse-event? e) (list 'mouse (mouse-event-action e) (mouse-event-button e)
                            (mods->symbols (mouse-event-mods e)))]
    [(resize-event? e) resize-binding]
    [(null-event? e) #f]
    [(other-event? e) #f]
    [else (error 'event->binding "不是 racket-tui 事件: ~a" e)]))

;; 文本通道取内容（#:text / #:paste 的 spec 用）。
(define (event-text ev)
  (cond
    [(key-event? ev) (define k (key-event-key ev)) (and (char? k) (string k))]
    [(paste-event? ev) (paste-event-text ev)]
    [else #f]))
