#lang racket

;;; edit4/backend/tui.rkt —— racket-tui 后端
;;;
;;; 输入：tui 事件 → edit4 Event；输出：piece → ANSI 字节。只有本模块碰终端。

(provide run-tui)

(require (prefix-in t: tui)
         "../core/event.rkt" "../runtime.rkt" "../view/theme.rkt"
         (only-in "../content/engine.rkt" piece-row piece-column piece-text piece-attr))

;;; ---------- 事件翻译 ----------

(define (mods->symbols m)
  (for/list ([s (in-list '(ctrl alt shift))]
             [on? (in-list (list (t:mods-ctrl? m) (t:mods-alt? m) (t:mods-shift? m)))]
             #:when on?)
    s))

(define (char->key-symbol c)
  (if (char=? c #\space) 'space (string->symbol (string-downcase (string c)))))

(define (translate ev)
  (cond
    [(t:key-event? ev)
     (define k (t:key-event-key ev))
     (define m (t:key-event-mods ev))
     (cond
       [(and (char? k) (not (t:mods-ctrl? m)) (not (t:mods-alt? m)))
        (text-event (string k))]
       [else (key-event (if (char? k) (char->key-symbol k) k) (mods->symbols m))])]
    [(t:paste-event? ev) (text-event (t:paste-event-text ev))]
    [(t:mouse-event? ev)
     (cursor-event (t:mouse-event-action ev) (t:mouse-event-button ev)
                   (max 0 (sub1 (t:mouse-event-x ev)))
                   (max 0 (sub1 (t:mouse-event-y ev))))]
    [(t:resize-event? ev) (resize-event (t:resize-event-cols ev) (t:resize-event-rows ev))]
    [else (resize-event 80 24)]))

;;; ---------- 画一帧 ----------

(define (draw! pieces prev-size size)
  (define fresh? (not (equal? size (unbox prev-size))))
  (set-box! prev-size size)
  (t:put-bytes t:format-cursor-hide)
  (when fresh? (t:put-bytes t:format-screen-clear))
  (for ([p (in-list pieces)])
    (t:put-bytes
     (bytes-append
      (t:format-cursor-move (add1 (piece-row p)) (add1 (piece-column p)))
      (attr-bytes (piece-attr p))
      (t:format-content (piece-text p))
      t:format-reset)))
  (t:flush!))

;;; ---------- 入口 ----------

(define (run-tui reg scopes km panels faces world)
  (t:with-tui
   (lambda ()
     (define-values (rows cols) (t:get-window-size))
     (define size-box (box (cons (or cols 80) (or rows 24))))
     (define prev-size (box #f))
     (define b
       (backend
        (lambda () (unbox size-box))
        (lambda ()
          (define ev (t:read-event))
          (cond
            [(t:resize-event? ev)
             (set-box! size-box (cons (t:resize-event-cols ev) (t:resize-event-rows ev)))
             (resize-event (t:resize-event-cols ev) (t:resize-event-rows ev))]
            [else (translate ev)]))
        (lambda (pieces) (draw! pieces prev-size (unbox size-box)))
        void))
     (run b reg scopes km panels faces world))))
