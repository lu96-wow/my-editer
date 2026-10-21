#lang racket

;;; edit-tui-rebuild/app/event.rkt —— 应用事件（纯值）

(provide (struct-out key-event)
         (struct-out mouse-event)
         (struct-out resize-event)
         (struct-out paste-event)
         (struct-out internal-event)
         (struct-out job-result-event)
         (struct-out timer-event)
         (struct-out quit-event)
         event? event-kind)

(struct key-event      (token)        #:transparent)
;; token = (key-token tag bytes)：终端标签 + 原始字节，不解码 char / symbol
(struct mouse-event    (token row col)#:transparent)
(struct resize-event   (rows cols)    #:transparent)
(struct paste-event    (bytes)        #:transparent)
;; 原始粘贴字节；解码在写进 buffer 时做一次
(struct internal-event (kind data)    #:transparent)
(struct job-result-event (id kind result tag) #:transparent)
(struct timer-event    (id)           #:transparent)
(struct quit-event     ()             #:transparent)

(define (event? x)
  (or (key-event? x) (mouse-event? x) (resize-event? x)
      (paste-event? x) (internal-event? x) (job-result-event? x)
      (timer-event? x) (quit-event? x)))

(define (event-kind x)
  (cond [(key-event? x)      'key]
        [(mouse-event? x)    'mouse]
        [(resize-event? x)   'resize]
        [(paste-event? x)    'paste]
        [(internal-event? x) 'internal]
        [(job-result-event? x) 'job-result]
        [(timer-event? x)    'timer]
        [(quit-event? x)     'quit]
        [else                'unknown]))
