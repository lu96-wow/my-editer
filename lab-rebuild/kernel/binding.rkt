#lang racket

;;; lab-rebuild/kernel/binding.rkt —— 事件 → 绑定键（纯）。
;;;
;;; 输入是 racket-tui 的规范化事件；输出是键表用的匿名绑定键。
;;; 与旧 lab 的 input.rkt 同构，独立成 lab-rebuild 的基石。

(require tui)

(provide (struct-out mods) no-mods no-mods? ->mods mods->list
         (struct-out key-event) (struct-out paste-event)
         (struct-out mouse-event) (struct-out resize-event)
         (struct-out null-event) (struct-out other-event)
         event?
         key mouse text-binding paste-binding resize-binding
         normalize-mods char->key-symbol
         mouse-col mouse-row
         event->binding)

(define mod-order '(ctrl alt shift))

(define (normalize-mods mods)
  (for/list ([m (in-list mod-order)] #:when (memq m mods)) m))

(define (mods->symbols m)
  (for/list ([sym (in-list mod-order)] [on? (in-list (mods->list m))] #:when on?) sym))

(define (char->key-symbol c)
  (if (char=? c #\space) 'space (string->symbol (string-downcase (string c)))))

(define (key k . mods) (list 'key k (normalize-mods mods)))
(define (mouse action [button #f] [mods '()])
  (list 'mouse action button (normalize-mods mods)))
(define text-binding 'text)
(define paste-binding 'paste)
(define resize-binding 'resize)

(define (mouse-col ev) (max 0 (sub1 (mouse-event-x ev))))
(define (mouse-row ev) (max 0 (sub1 (mouse-event-y ev))))

(define (event->binding e)
  (cond
    [(key-event? e)
     (define k (key-event-key e))
     (define m (key-event-mods e))
     (cond
       [(and (char? k) (not (mods-ctrl? m)) (not (mods-alt? m))) text-binding]
       [else (list 'key (if (char? k) (char->key-symbol k) k) (mods->symbols m))])]
    [(paste-event? e) paste-binding]
    [(mouse-event? e)
     (list 'mouse (mouse-event-action e) (mouse-event-button e)
           (mods->symbols (mouse-event-mods e)))]
    [(resize-event? e) resize-binding]
    [(null-event? e) #f]
    [(other-event? e) #f]
    [else (error 'event->binding "不是 racket-tui 事件: ~a" e)]))
