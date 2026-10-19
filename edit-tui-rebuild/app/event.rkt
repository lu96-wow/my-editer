#lang racket

;;; edit-tui-rebuild/app/event.rkt —— 应用事件（纯值）

(provide (struct-out key-event)
         (struct-out mouse-event)
         (struct-out resize-event)
         (struct-out paste-event)
         (struct-out internal-event)
         (struct-out quit-event)
         event? event-kind)

(struct key-event      (token)        #:transparent)
(struct mouse-event    (token row col)#:transparent)
(struct resize-event   (rows cols)    #:transparent)
(struct paste-event    (text)         #:transparent)
(struct internal-event (kind data)    #:transparent)
(struct quit-event     ()             #:transparent)

(define (event? x)
  (or (key-event? x) (mouse-event? x) (resize-event? x)
      (paste-event? x) (internal-event? x) (quit-event? x)))

(define (event-kind x)
  (cond [(key-event? x)      'key]
        [(mouse-event? x)    'mouse]
        [(resize-event? x)   'resize]
        [(paste-event? x)    'paste]
        [(internal-event? x) 'internal]
        [(quit-event? x)     'quit]
        [else                'unknown]))
