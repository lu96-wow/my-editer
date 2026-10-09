#lang racket

;;; edit/command/binding.rkt —— 事件 → 绑定键（tui 后端层）
;;;
;;; 唯一把 racket-tui 事件解码成绑定键的模块。绑定键 / spec 的纯构造在 key.rkt，
;;; 这里 re-export，方便只需构造的调用方少 require 一个模块。
;;;
;;; 输出：
;;;     (key k ctrl …) / (mouse action button mods) / text / paste / resize
;;; 换后端只要换这一层。

(require tui "key.rkt")

(provide event->binding event-text mouse-col mouse-row
         (all-from-out "key.rkt"))

(define (mods->symbols m)
  (for/list ([sym (in-list mod-order)]
             [on? (in-list (list (mods-ctrl? m) (mods-alt? m) (mods-shift? m)))]
             #:when on?)
    sym))

;; 鼠标坐标（屏幕 0-based）：tui 是 1-based，减 1。
(define (mouse-col ev) (max 0 (sub1 (mouse-event-x ev))))
(define (mouse-row ev) (max 0 (sub1 (mouse-event-y ev))))

;; 事件 → 绑定键（无法绑定的 → #f）。
;; chars-as-keys? #t（前缀激活时）：普通字符也解成命名键（如 - / \），不走文本通道。
(define (event->binding e [chars-as-keys? #f])
  (cond
    [(key-event? e)
     (define k (key-event-key e))
     (define m (key-event-mods e))
     (cond
       [(and (char? k) (not (mods-ctrl? m)) (not (mods-alt? m)))
        (if chars-as-keys?
            (list 'key (char->key-symbol k) '())
            text-binding)]
       [else (list 'key (if (char? k) (char->key-symbol k) k) (mods->symbols m))])]
    [(paste-event? e) paste-binding]
    [(mouse-event? e) (list 'mouse (mouse-event-action e) (mouse-event-button e)
                            (mods->symbols (mouse-event-mods e)))]
    [(resize-event? e) resize-binding]
    [(null-event? e) #f]
    [(other-event? e) #f]
    [else (error 'event->binding "不是 racket-tui 事件: ~a" e)]))

;; 文本通道取内容（text-spec 用）。
(define (event-text ev)
  (cond
    [(key-event? ev) (define k (key-event-key ev)) (and (char? k) (string k))]
    [(paste-event? ev) (paste-event-text ev)]
    [else #f]))
