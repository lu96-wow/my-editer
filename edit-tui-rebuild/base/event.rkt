#lang racket

;;; base/event.rkt —— 应用事件（纯值，不依赖 tui）
;;;
;;; Runtime 的 tui 适配层把终端事件解码成这里的值；reducer 只认识这些值。
;;; 于是 step / dispatch 可以在 headless 下直接喂事件，不需要终端。
;;;
;;; 值词汇：
;;;   key-event      token（command/key 的键令牌）
;;;   mouse-event    token（command/mouse 的鼠标令牌）+ 0-based (row, col)
;;;   resize-event   rows cols
;;;   paste-event    text
;;;   internal-event kind payload      异步 / IO 结果回投
;;;   tick-event     id                定时器 / idle
;;;   quit-event     —                 外部请求退出
;;;
;;; 注意：mouse token 里已经有 action / button；row/col 不进 token（位置不是绑定的一部分）。

(provide (struct-out key-event)
         (struct-out mouse-event)
         (struct-out resize-event)
         (struct-out paste-event)
         (struct-out internal-event)
         (struct-out tick-event)
         (struct-out quit-event)
         event? event-kind)

(struct key-event      (token)        #:transparent)
(struct mouse-event    (token row col)#:transparent)
(struct resize-event   (rows cols)    #:transparent)
(struct paste-event    (text)         #:transparent)
(struct internal-event (kind payload) #:transparent)
(struct tick-event     (id)           #:transparent)
(struct quit-event     ()             #:transparent)

(define (event? x)
  (or (key-event? x) (mouse-event? x) (resize-event? x)
      (paste-event? x) (internal-event? x) (tick-event? x) (quit-event? x)))

(define (event-kind x)
  (cond [(key-event? x)      'key]
        [(mouse-event? x)    'mouse]
        [(resize-event? x)   'resize]
        [(paste-event? x)    'paste]
        [(internal-event? x) 'internal]
        [(tick-event? x)     'tick]
        [(quit-event? x)     'quit]
        [else                'unknown]))
