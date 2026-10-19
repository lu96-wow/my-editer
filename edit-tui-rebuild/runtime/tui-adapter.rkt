#lang racket

;;; edit-tui-rebuild/runtime/tui-adapter.rkt —— tui event -> app event

(require tui
         (prefix-in a: "../app/event.rkt")
         "../command/api.rkt")

(provide tui-event->app)

(define (mods->symbols m)
  (for/list ([s (in-list '(ctrl alt shift))]
             [on? (in-list (list (mods-ctrl? m)
                                 (mods-alt? m)
                                 (mods-shift? m)))]
             #:when on?)
    s))

(define (event->key ev)
  (apply key (key-event-key ev) (mods->symbols (key-event-mods ev))))

(define (event->mouse-token ev)
  (case (mouse-event-action ev)
    [(press) 'press]
    [(release) 'release]
    [(move) 'move]
    [(scroll) (if (eq? (mouse-event-button ev) 'up)
                  'scroll-up
                  'scroll-down)]
    [else 'move]))

(define (tui-event->app ev)
  (cond
    [(key-event? ev)
     (a:key-event (event->key ev))]
    [(mouse-event? ev)
     (a:mouse-event (event->mouse-token ev)
                    (max 0 (sub1 (mouse-event-y ev)))
                    (max 0 (sub1 (mouse-event-x ev))))]
    [(resize-event? ev)
     (a:resize-event (resize-event-rows ev) (resize-event-cols ev))]
    [(paste-event? ev)
     (a:paste-event (paste-event-text ev))]
    [else #f]))
