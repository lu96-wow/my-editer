#lang racket

;;; edit/tui.rkt —— racket-tui 输入 / 输出后端
;;;
;;; 输入：read-event -> resolve（session 的键表叠）-> step（纯）-> session
;;; 输出：session -> core 合成 -> pieces -> format-* 字节
;;;
;;; 只有本模块碰终端 / FFI；command.rkt / layout.rkt / focus.rkt 保持纯。

(require tui
         "command/command.rkt"
         "command/session.rkt"
         "command/binding.rkt"
         "core/keymap.rkt"
         "../core/view/base/screen.rkt"
         "../core/view/patch.rkt")

(provide resolve render-pieces draw! run-tui)

;;; ---------- 输入：event -> cmd（走 session 的键表叠） ----------

(define (resolve s ev)
  (define b (event->binding ev))
  (define did (session-focused-did s))
  (define kms (append (if did (list (session-doc-keys s did)) '())
                      (session-keys s)))
  (and b
       (for/or ([km (in-list kms)])
         (define spec (keymap-lookup km b))
         (and spec (if (procedure? spec) (spec ev) spec)))))

;;; ---------- 输出：session -> pieces ----------

;; 一帧的全部 piece（render + selection）。old = #f 表示全量。
(define (render-pieces s [old #f])
  (define-values (_new rends sels) (session-patch s old))
  (append rends sels))

;; piece 的外观：目前只处理光标 overlay（反色），face 配色留给主题。
(define (piece-style attr)
  (define ov (and (pair? attr) (car attr)))
  (if (eq? ov 'cursor) format-reverse #""))

;;; ---------- 画一帧（增量） ----------

(define prev (box #f))

(define (draw! s)
  (define old (unbox prev))
  (define-values (new rends sels) (session-patch s old))
  (define fresh? (or (not old)
                     (not (= (screen-width old) (screen-width new)))
                     (not (= (screen-height old) (screen-height new)))))
  (set-box! prev new)
  (put-bytes format-cursor-hide)
  (when fresh? (put-bytes format-screen-clear))
  (for ([p (in-list (append rends sels))])
    (put-bytes (bytes-append
                (format-cursor-move (add1 (piece-row p)) (add1 (piece-column p)))
                (piece-style (piece-attr p))
                (format-content (piece-text p))
                format-reset)))
  (flush!))

;;; ---------- 主循环 ----------

(define (run-tui s0)
  (with-tui
   (lambda ()
     (define-values (rows cols) (get-window-size))
     (define s (struct-copy session s0
                            [width (or cols (session-width s0))]
                            [height (or rows (session-height s0))]))
     (set-box! prev #f)
     (let loop ([s s])
       (draw! s)
       (define ev (read-event))
       (define c (resolve s ev))
       (define s* (if c (step s c) s))
       (unless (session-quit? s*) (loop s*))))))
