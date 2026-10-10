#lang racket

;;; edit-rebuild/core/command/key.rkt —— 绑定键 / spec 构造（纯，不碰 tui）
;;;
;;; 键表与事件编码解耦的最低层：只造「匿名绑定键」与几个 spec 标记。
;;;     (key k ctrl …)        命名键 / 带修饰的字符键
;;;     (mouse action button mods)
;;;     text-binding / paste-binding / resize-binding   特殊通道的绑定键
;;;     text-spec             文本通道的 spec 标记（resolve 取事件文本 → cmd-insert）
;;;
;;; 事件 → 绑定键的解码（event->binding）在 binding.rkt（唯一碰 tui）。

(provide mod-order normalize-mods char->key-symbol
         key mouse
         text-binding paste-binding resize-binding text-spec
         resize-spec mouse-press-spec mouse-scroll-up-spec mouse-scroll-down-spec)

(define mod-order '(ctrl alt shift))

(define (normalize-mods mods)
  (for/list ([m (in-list mod-order)] #:when (memq m mods)) m))

(define (char->key-symbol c)
  (if (char=? c #\space) 'space (string->symbol (string-downcase (string c)))))

;; 构造绑定键（config 用）。
(define (key k . mods) (list 'key k (normalize-mods mods)))
(define (mouse action [button #f] [mods '()])
  (list 'mouse action button (normalize-mods mods)))

(define text-binding 'text)
(define paste-binding 'paste)
(define resize-binding 'resize)

;; 文本通道的 spec：resolve 见到它就取事件里的文本 → (cmd-insert text)。
;; 这样键表配置不必 require tui（event-text）。
(define text-spec 'text-spec)

;; 需要从事件取数据的 spec（鼠标 / resize）。由后端 resolve 处理；
;; 键表配置只写标记，不 require tui。
(define resize-spec 'resize-spec)
(define mouse-press-spec 'mouse-press-spec)
(define mouse-scroll-up-spec 'mouse-scroll-up-spec)
(define mouse-scroll-down-spec 'mouse-scroll-down-spec)
