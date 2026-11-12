#lang racket

;;; edit-tui-rebuild/host/event.rkt —— host 事件 + tui raw 适配
;;;
;;; 事件只属于 host；editor 操作面只接受 state + 参数，不认识终端事件。

(require racket/match
         (prefix-in tui: tui)
         "../core/command/api.rkt"
         "../editor/job.rkt"
         "../editor/timer.rkt")

(provide (struct-out key-event)
         (struct-out mouse-event)
         (struct-out resize-event)
         (struct-out paste-event)
         (struct-out quit-event)
         event?
         event-kind
         tui-event->app)

(struct key-event (token) #:transparent)
(struct mouse-event (token row col) #:transparent)
(struct resize-event (rows cols) #:transparent)
(struct paste-event (bytes) #:transparent)
(struct quit-event () #:transparent)

(define (event? x)
  (or (key-event? x) (mouse-event? x) (resize-event? x)
      (paste-event? x) (quit-event? x) (job-result-event? x)
      (timer-event? x)))

(define (event-kind x)
  (cond [(key-event? x) 'key]
        [(mouse-event? x) 'mouse]
        [(resize-event? x) 'resize]
        [(paste-event? x) 'paste]
        [(quit-event? x) 'quit]
        [else 'unknown]))

(define (raw-mouse->app data)
  (match data
    [(list 'press _b x y _m)
     (mouse-event 'press (max 0 (sub1 y)) (max 0 (sub1 x)))]
    [(list 'release _b x y _m)
     (mouse-event 'release (max 0 (sub1 y)) (max 0 (sub1 x)))]
    [(list 'move _b x y _m)
     (mouse-event 'move (max 0 (sub1 y)) (max 0 (sub1 x)))]
    [(list 'scroll _btn dir x y _m)
     (mouse-event (if (eq? dir 'up) 'scroll-up 'scroll-down)
                  (max 0 (sub1 y)) (max 0 (sub1 x)))]
    [_ #f]))

(define (tui-event->app type data _mods)
  (case type
    [(null) #f]
    [(resize) (resize-event (car data) (cdr data))]
    [(paste) (paste-event data)]
    [(mouse) (raw-mouse->app data)]
    [else (key-event (raw-key-token type data))]))
